#!/bin/bash
set -e

if [ "${1:-}" = "--check-claude-update" ]; then
    echo "== Checking for claude-desktop-unofficial updates =="
    if apt-get update -qq -o Acquire::ForceIPv4=true \
        -o Dir::Etc::SourceList=/etc/apt/sources.list.d/claude-desktop-unofficial.list \
        -o Dir::Etc::SourceParts=/dev/null >/dev/null 2>&1; then
        installed_version=$(dpkg-query -W -f='${Version}' claude-desktop-unofficial 2>/dev/null || true)
        candidate_version=$(apt-cache policy claude-desktop-unofficial 2>/dev/null | awk '/Candidate:/ {print $2}')
        if [[ -n "$candidate_version" && "$installed_version" != "$candidate_version" ]]; then
            echo "!! claude-desktop-unofficial is outdated: installed $installed_version, latest $candidate_version"
            echo ""
            echo "To update, rebuild the image with a cache-bust so this step re-runs instead of reusing the cached layer:"
            echo "  docker build --network=host -t claude-desktop-proxy-container \\"
            echo "      --build-arg PUID=\$(id -u) --build-arg PGID=\$(id -g) \\"
            echo "      --build-arg CACHEBUST=\$(date +%s) ."
        else
            echo "== claude-desktop-unofficial is up to date ($installed_version) =="
        fi
    else
        echo "!! Could not check for claude-desktop-unofficial updates (no network) — try again in a moment"
    fi
    exit 0
fi

echo "== Killswitch: blocking everything except lo / root (sing-box) / tun0 =="
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

if [ -n "${PORT_REDIRECTS:-}" ]; then
    echo "== Applying port redirects =="
    # Captured now, before sing-box installs its own routes via tun0 — a
    # redirect's traffic needs to go out the original way instead.
    _default_route_dev=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
    _default_route_via=$(ip route show default | head -1 | awk '{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}')
    _redirect_rule_pref=100
    IFS=',' read -ra _redirects <<< "$PORT_REDIRECTS"
    for r in "${_redirects[@]}"; do
        [ -z "$r" ] && continue
        proto="tcp"
        case "$r" in
            */udp) proto="udp"; r="${r%/udp}" ;;
            */tcp) proto="tcp"; r="${r%/tcp}" ;;
        esac
        local_port="${r%%:*}"
        rest="${r#*:}"
        remote_host="${rest%%:*}"
        remote_port="${rest#*:}"
        echo "  $local_port/$proto -> $remote_host:$remote_port (bypasses proxy)"
        # The filter-table ACCEPT below only decides whether the packet is
        # allowed — routing still decides which interface it goes out on,
        # and sing-box's auto_route sends everything via tun0. A specific
        # host route wins over that (longest-prefix-match).
        if [ -n "$_default_route_dev" ]; then
            if [ -n "$_default_route_via" ]; then
                ip route replace "$remote_host/32" via "$_default_route_via" dev "$_default_route_dev"
            else
                ip route replace "$remote_host/32" dev "$_default_route_dev"
            fi
            # sing-box's auto_route uses policy rules pointing at its own
            # table, consulted before main. A rule with a lower pref (=
            # higher priority) forces main to be checked first for this
            # one destination.
            ip rule add to "$remote_host" lookup main pref "$_redirect_rule_pref" 2>/dev/null
            _redirect_rule_pref=$((_redirect_rule_pref + 1))
        else
            echo "  !! could not determine the pre-tunnel default route — this redirect may still go through the proxy" >&2
        fi
        iptables -t nat -A OUTPUT -p "$proto" --dport "$local_port" -j DNAT --to-destination "$remote_host:$remote_port"
        # A connection originally addressed to 127.0.0.1 keeps that as its
        # source unless something rewrites it too — the remote server can't
        # reply to that address, so the handshake never completes even
        # though the initial connect() succeeds. MASQUERADE fixes the
        # source to the container's real outbound address.
        iptables -t nat -A POSTROUTING -p "$proto" -d "$remote_host" --dport "$remote_port" -j MASQUERADE
        # DNAT already rewrote the destination by the time this chain sees
        # the packet, so this only ever matches this specific redirect's
        # traffic — not a blanket tunnel bypass.
        iptables -A OUTPUT -p "$proto" -d "$remote_host" --dport "$remote_port" -j ACCEPT
    done
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

echo "== Verifying traffic actually flows through the proxy =="
proxy_ok=0
for i in $(seq 1 5); do
    http_code=$(curl -sS -m 10 -o /tmp/ipapi.json -w '%{http_code}' http://ip-api.com/json 2>/dev/null || true)
    if [ "$http_code" = "200" ] && jq -e . /tmp/ipapi.json >/dev/null 2>&1; then
        echo "== Proxy OK: $(jq -r '"\(.query) (\(.city), \(.country))"' /tmp/ipapi.json) =="
        proxy_ok=1
        break
    fi
    echo "  attempt $i/5 failed (http='${http_code:-none}'), retrying..."
    sleep 5
done
rm -f /tmp/ipapi.json
if [ "$proxy_ok" -ne 1 ]; then
    echo "!! tun0 is up but requests to ip-api.com do not return HTTP 200 with valid JSON after 5 attempts — stopping"
    echo "!! Check: docker exec -it claude-desktop-proxy tail -40 /var/log/sing-box.log"
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

echo "== Registering claude:// URL handler (for OAuth/login redirects, e.g. Google sign-in) =="
sudo -u claude XDG_DATA_HOME=/home/claude/.local/share xdg-mime default claude-desktop-unofficial.desktop x-scheme-handler/claude

exec sudo -u claude -H \
    env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
    dbus-run-session -- bash -c '
        eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets,pkcs11)"
        eval "$(printf "\n" | gnome-keyring-daemon --start --components=secrets,pkcs11)"
        export GNOME_KEYRING_CONTROL
        exec "$@"
    ' bash "$@"
