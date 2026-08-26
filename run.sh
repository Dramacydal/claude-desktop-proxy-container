#!/bin/bash
HOME_DIR=""
LOCATION=""

while [[ "$1" == --home || "$1" == --location ]]; do
    if [[ "$1" == --home ]]; then
        HOME_DIR="$2"
    elif [[ "$1" == --location ]]; then
        LOCATION="$2"
    fi
    shift 2
done

if [[ -z "$HOME_DIR" || -z "$LOCATION" ]]; then
    echo "Usage: $0 --home /path/to/home --location <location_code> [command]"
    exit 1
fi

mkdir -p "$HOME_DIR"

ADGUARD_CONFIG_DIR="$HOME_DIR/.adguard-vpn-config"
mkdir -p "$ADGUARD_CONFIG_DIR"

MAC_FILE="$HOME_DIR/.container-mac"
if [[ ! -f "$MAC_FILE" ]]; then
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
        > "$MAC_FILE"
fi
CONTAINER_MAC=$(cat "$MAC_FILE")

docker run -it --rm \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --shm-size=1g \
    --mac-address="$CONTAINER_MAC" \
    --hostname="claude-desktop-vpn-container" \
    -v "$HOME_DIR:/home/claude" \
    -v "$ADGUARD_CONFIG_DIR:/root/.local/share/adguardvpn-cli" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v /mnt/wslg/runtime-dir:/mnt/wslg/runtime-dir \
    -e DISPLAY="$DISPLAY" \
    -e WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    -e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir \
    -e PULSE_SERVER=unix:/mnt/wslg/runtime-dir/pulse/native \
    -e VPN_LOCATION="$LOCATION" \
    --name claude-desktop-vpn \
    claude-desktop-vpn-container \
    "${@:-claude-desktop-unofficial}"
