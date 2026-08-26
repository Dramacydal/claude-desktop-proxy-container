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

if [[ -d /mnt/wslg ]]; then
    # WSL2: WSLg exposes X11/Wayland/PulseAudio sockets under one runtime dir.
    AUDIO_RUNTIME_DIR="/mnt/wslg/runtime-dir"
else
    # Native Linux: sockets live under the desktop session's own XDG runtime dir.
    AUDIO_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
fi

if [[ ! -d "$AUDIO_RUNTIME_DIR" ]]; then
    echo "!! Runtime dir $AUDIO_RUNTIME_DIR not found — audio passthrough will likely fail" >&2
fi

PULSE_SOCKET="unix:${AUDIO_RUNTIME_DIR}/pulse/native"

docker run -it --rm \
    --cap-add=NET_ADMIN \
    --device=/dev/net/tun \
    --shm-size=1g \
    --mac-address="$CONTAINER_MAC" \
    --hostname="claude-desktop-vpn-container" \
    -v "$HOME_DIR:/home/claude" \
    -v "$ADGUARD_CONFIG_DIR:/root/.local/share/adguardvpn-cli" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$AUDIO_RUNTIME_DIR:$AUDIO_RUNTIME_DIR" \
    -e DISPLAY="$DISPLAY" \
    -e WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    -e XDG_RUNTIME_DIR="$AUDIO_RUNTIME_DIR" \
    -e PULSE_SERVER="$PULSE_SOCKET" \
    -e VPN_LOCATION="$LOCATION" \
    --name claude-desktop-vpn \
    claude-desktop-vpn-container \
    "${@:-claude-desktop-unofficial}"
