#!/bin/bash
set -e

echo "== Killswitch: blocking everything except lo / root (sing-box) / tun0 =="
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

echo "== Checking for claude-desktop-unofficial updates =="
if apt-get update -qq -o Acquire::ForceIPv4=true \
    -o Dir::Etc::SourceList=/etc/apt/sources.list.d/claude-desktop-unofficial.list \
    -o Dir::Etc::SourceParts=/dev/null >/dev/null 2>&1; then
    installed_version=$(dpkg-query -W -f='${Version}' claude-desktop-unofficial 2>/dev/null || true)
    candidate_version=$(apt-cache policy claude-desktop-unofficial 2>/dev/null | awk '/Candidate:/ {print $2}')
    if [[ -n "$candidate_version" && "$installed_version" != "$candidate_version" ]]; then
        echo "!! claude-desktop-unofficial is outdated: installed $installed_version, latest $candidate_version — rebuild the image to update"
    else
        echo "== claude-desktop-unofficial is up to date ($installed_version) =="
    fi
else
    echo "!! Could not check for claude-desktop-unofficial updates (no network yet) — skipping"
fi

if [ -z "$PROXY_FILE" ] || [ ! -f "$PROXY_FILE" ]; then
    echo "!! PROXY_FILE not set or not found, stopping"
    exit 1
fi

echo "== Generating sing-box config from $PROXY_FILE =="
mkdir -p /etc/sing-box

# First non-blank, non-comment line wins — lets the file hold several
# proxies with all but one commented out (#) for easy switching.
PROXY_URL=$(grep -vE '^[[:space:]]*(#|$)' "$PROXY_FILE" | head -n1 | tr -d '\r\n')
if [ -z "$PROXY_URL" ]; then
    echo "!! No active proxy line found in $PROXY_FILE (everything is commented out or empty), stopping"
    exit 1
fi

PROXY_URL="$PROXY_URL" python3 - > /etc/sing-box/config.json <<'PYEOF'
import json
import os
import sys
from urllib.parse import urlsplit

url = os.environ["PROXY_URL"].strip()
parsed = urlsplit(url)

scheme_map = {"socks5": "socks", "socks": "socks", "http": "http", "https": "http"}
if parsed.scheme not in scheme_map:
    sys.exit(f"!! Unsupported proxy scheme '{parsed.scheme}', expected socks5://, http:// or https://")
if not parsed.hostname or not parsed.port:
    sys.exit("!! Proxy URL must include host and port, e.g. socks5://user:pass@host:port")

outbound = {
    "type": scheme_map[parsed.scheme],
    "tag": "proxy-out",
    "server": parsed.hostname,
    "server_port": parsed.port,
}
if parsed.username:
    outbound["username"] = parsed.username
if parsed.password:
    outbound["password"] = parsed.password
# https:// means an HTTP-proxy protocol carried over a TLS connection to the
# proxy server itself (common for paid proxy providers), not a SOCKS/HTTP
# distinction — so it reuses the "http" outbound with TLS turned on.
if parsed.scheme == "https":
    outbound["tls"] = {"enabled": True, "server_name": parsed.hostname}

config = {
    "log": {"level": "info", "output": "/var/log/sing-box.log"},
    "inbounds": [
        {
            "type": "tun",
            "interface_name": "tun0",
            "address": ["172.19.0.1/30"],
            "auto_route": True,
            "strict_route": True,
            "stack": "system",
        }
    ],
    "outbounds": [outbound, {"type": "direct", "tag": "direct-out"}],
    "dns": {
        "servers": [
            # Resolves the proxy server's own hostname directly, bypassing
            # the tunnel — needed just to open the connection *to* it in the
            # first place. sing-box runs as root, which the killswitch always
            # lets out regardless of interface, so this doesn't leak: it's
            # only ever used to look up the proxy's own address, never the
            # client's actual traffic. Without this, resolving a proxy given
            # as a hostname (not a bare IP) deadlocks: to connect to the
            # proxy you'd first need to resolve it, but resolving anything
            # here goes back through the very outbound you're trying to reach.
            {"tag": "dns-direct", "address": "1.1.1.1", "detour": "direct-out"},
            # DNS-over-HTTPS for everything else (actual client lookups): a
            # plain UDP:53 query can't cross an http/https outbound (HTTP
            # proxies only carry TCP CONNECT) — DoH rides TCP instead.
            {"tag": "proxy-dns", "address": "https://1.1.1.1/dns-query", "detour": "proxy-out"},
        ],
        "rules": [{"outbound": "proxy-out", "server": "dns-direct"}],
        "final": "proxy-dns",
    },
    "route": {
        # Without this, DNS queries would just be forwarded as raw UDP
        # packets through proxy-out instead of being answered by the
        # "dns" block above — and raw UDP can't cross an http(s) proxy.
        "rules": [{"port": 53, "action": "hijack-dns"}],
        "final": "proxy-out",
        "auto_detect_interface": True,
    },
}
json.dump(config, sys.stdout, indent=2)
PYEOF

echo "== Bringing up sing-box tun (killswitch already in place) =="
sing-box run -c /etc/sing-box/config.json &

echo "== Waiting for tun0 =="
for i in $(seq 1 30); do
    if ip link show tun0 >/dev/null 2>&1; then
        echo "== tun0 is up =="
        ip link set dev tun0 mtu 1400
        break
    fi
    sleep 1
done

if ! ip link show tun0 >/dev/null 2>&1; then
    echo "!! tun0 did not come up within 30 seconds — network is blocked by the killswitch, stopping"
    echo "!! Check the log: docker exec -it claude-desktop-proxy tail -40 /var/log/sing-box.log"
    exit 1
fi

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
mkdir -p /tmp/runtime-claude
chown claude:claude /tmp/runtime-claude
chmod 700 /tmp/runtime-claude
export XDG_RUNTIME_DIR="/tmp/runtime-claude"

export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/runtime-dir/pulse/native}"

mkdir -p /home/claude/.local/share/keyrings
chown -R claude:claude /home/claude/.local/share/keyrings

LAUNCHER_CONFIG="/home/claude/.config/claude-desktop-debian/environment"
if [ ! -f "$LAUNCHER_CONFIG" ]; then
    echo "== Setting CLAUDE_PASSWORD_STORE=basic (plain storage, no keyring/D-Bus dependency) =="
    mkdir -p "$(dirname "$LAUNCHER_CONFIG")"
    echo "CLAUDE_PASSWORD_STORE=basic" > "$LAUNCHER_CONFIG"
    chown -R claude:claude /home/claude/.config
fi

exec sudo -u claude -H \
    env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
    dbus-run-session -- bash -c '
        eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets,pkcs11)"
        eval "$(printf "\n" | gnome-keyring-daemon --start --components=secrets,pkcs11)"
        export GNOME_KEYRING_CONTROL
        exec "$@"
    ' bash "$@"
