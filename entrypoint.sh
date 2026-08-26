#!/bin/bash
set -e

echo "== Killswitch: blocking everything except lo / root (VPN infra) / tun0 =="
iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner 0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT

echo "== Checking AdGuard login =="
status_output=$(adguardvpn-cli status 2>&1) || true
if printf '%s\n' "$status_output" | grep -qiE \
    'not logged in|authentication required|login required|unauthorized|session expired|invalid session'; then
    echo "== Login not found, starting interactive login =="
    adguardvpn-cli login
fi

if [ -z "$VPN_LOCATION" ]; then
    echo "!! VPN_LOCATION not set, stopping"
    exit 1
fi

echo "== Bringing up VPN =="
adguardvpn-cli connect -l "$VPN_LOCATION" --boot -y

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
    echo "!! Check: docker exec -it claude-desktop-vpn adguardvpn-cli status"
    echo "!! And the log: docker exec -it claude-desktop-vpn tail -40 /root/.local/share/adguardvpn-cli/tunnel.log"
    exit 1
fi

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
mkdir -p /tmp/runtime-claude
chown claude:claude /tmp/runtime-claude
chmod 700 /tmp/runtime-claude
export XDG_RUNTIME_DIR="/tmp/runtime-claude"

#mkdir -p /home/claude/.local/share/keyrings
#chown -R claude:claude /home/claude/.local/share/keyrings

export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/runtime-dir/pulse/native}"

#exec sudo -u claude -H env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" "$@"

mkdir -p /home/claude/.local/share/keyrings
chown -R claude:claude /home/claude/.local/share/keyrings

exec sudo -u claude -H \
    env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PULSE_SERVER="$PULSE_SERVER" \
    dbus-run-session -- bash -c '
        eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)"
        eval "$(printf "\n" | gnome-keyring-daemon --start --components=secrets,pkcs11,ssh)"
        export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
        exec "$@"
    ' bash "$@"
