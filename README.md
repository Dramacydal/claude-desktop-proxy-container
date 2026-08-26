# Claude Desktop in a VPN-Isolated Docker Container

Runs [Claude Desktop](https://github.com/aaddrick/claude-desktop-debian) inside a Docker container with **all traffic forced through AdGuard VPN** and a **killswitch** — if the VPN drops, the container loses network access entirely instead of leaking traffic through your regular connection. GUI is forwarded to Windows via WSLg (X11/Wayland), including audio and microphone.

## How it works

- The container has its own isolated network namespace (unlike separate WSL2 distros, which share one).
- `entrypoint.sh` sets a default-DROP `iptables` policy, brings up AdGuard VPN CLI (TUN mode), waits for the `tun0` interface, then allows traffic only through it (plus loopback and the VPN process itself).
- If the VPN never connects, the container refuses to start the GUI app instead of running with a broken killswitch.
- GUI is displayed via X11 (`/tmp/.X11-unix`, bind-mounted from the host — the app runs in X11-via-XWayland mode, see `--doctor` output). Audio and microphone go through PulseAudio, whose socket lives in `/mnt/wslg/runtime-dir/pulse/native`. Both are provided by WSLg, which Windows already exposes to WSL2.
- Your home directory and VPN login are stored outside the container (both bind-mounted from the host), so they survive container restarts. The container itself is ephemeral — it only exists while the main process (Claude Desktop) is running.

## Prerequisites

- **Windows 11** with WSL2 and a Linux distro (tested on Debian).
- **`.wslconfig` must use NAT networking**, not mirrored:
```ini
  [wsl2]
  networkingMode=NAT
```
  (Mirrored mode breaks Docker's bridge networking on some setups — see Troubleshooting.)
- **Docker Engine** installed inside the WSL2 distro (not Docker Desktop):
```bash
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker $USER   # then re-login or `newgrp docker`
  sudo systemctl enable --now docker
```
- An **AdGuard VPN account** (the CLI will prompt you to log in on first run).

Node.js is installed in the image alongside the packages above because `claude-desktop-unofficial` depends on it.

## Project files
~/claude-desktop-vpn-container/
├── Dockerfile # image definition
├── entrypoint.sh # killswitch + VPN bring-up + GUI launch, runs as container PID 1
├── run.sh # wrapper around docker run with the right flags
└── README.md


## Setup

1. Clone/create the project directory and add `Dockerfile`, `entrypoint.sh`, `run.sh` (see repo).
2. Build the image:
```bash
   cd ~/claude-desktop-vpn-container
   docker build --network=host -t claude-desktop-vpn-container \
       --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) .
```
   `--network=host` is required for the build itself — some WSL2/Docker setups fail to resolve DNS over the default bridge network during `docker build` (see Troubleshooting). It has no effect on the container at runtime.

3. Pick a home directory for the container (anything you like, created automatically):
```bash
   mkdir -p ~/claude-container-home
```

## First run (VPN login)

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location <LOCATION_CODE> bash
```

Replace `<LOCATION_CODE>` with an AdGuard VPN location code (e.g. `SG`, `DE`, `US`). Run `adguardvpn-cli list-locations` inside a container to see available codes if unsure.

On first launch, `entrypoint.sh` will detect there's no saved login and print a device-authorization link:
```
You need to authorize in your browser. The following link will be available for 1799 seconds: https://...
```


Open that link in a Windows browser and log in with your AdGuard account. The VPN config (including the login token) is stored in `<home>/.adguard-vpn-config`, bind-mounted from your home directory; the container also uses a fixed hostname and a MAC address generated on first run (then reused via `.container-mac`) — **both are required** for AdGuard to recognize the session as the same device on subsequent runs. Don't delete `.container-mac` or `.adguard-vpn-config` in your home directory unless you want a fresh device identity.

## Normal usage

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG
```

With no trailing command, this launches `claude-desktop-unofficial` (the GUI) directly. The container:
1. Sets up the killswitch.
2. Confirms you're logged in to AdGuard (skips the login prompt if already authenticated).
3. Connects to the VPN and waits (up to 30s) for `tun0`.
4. If the VPN fails to come up, the container **exits** rather than launching the GUI in a broken state — check `docker exec -it claude-desktop-vpn adguardvpn-cli status` and `docker exec -it claude-desktop-vpn tail -40 /root/.local/share/adguardvpn-cli/tunnel.log`.
5. Launches Claude Desktop with GUI/audio/mic forwarded to your Windows session.

Closing the Claude Desktop window doesn't necessarily stop the container — like on native Linux, the app may keep running in the background. To fully stop everything:

```bash
docker rm -f claude-desktop-vpn
```

### Running other commands in the container

Since `run.sh` accepts a trailing command, you can use the same VPN-protected environment for other things:

```bash
# doctor diagnostics
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG claude-desktop-unofficial --doctor

# quick connectivity check
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG curl ip-api.com

# shell access
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG bash
```

### Inspecting a running container

```bash
docker ps -a                          # see if it's running
docker exec -it claude-desktop-vpn bash       # shell into a running container
docker exec -it claude-desktop-vpn adguardvpn-cli status
docker exec -it claude-desktop-vpn curl -m5 ip-api.com   # should show your VPN location, not your real one
```

## Troubleshooting

**`docker build` hangs or times out resolving DNS.**
Rebuild with `--network=host`. If `apt-get` inside the Dockerfile hangs specifically (not fails), it's usually an IPv6 connectivity gap in WSL2 — the Dockerfile already forces IPv4 via `Acquire::ForceIPv4=true` and `curl -4`.

**Docker containers have no network access at all (build or runtime), even though the WSL2 host does.**
Check `.wslconfig` — if `networkingMode=mirrored`, switch to `NAT` (see Prerequisites) and `wsl --shutdown`, then restart Docker. Mirrored mode has been observed to break Docker's bridge/NAT forwarding on some Windows builds.

**Claude Desktop window is blank / doesn't render / can't be dragged.**
This was Docker's default 64MB `/dev/shm`, too small for Chromium's multi-process rendering. Already fixed via `--shm-size=1g` in `run.sh` — if you removed that flag, add it back.

**MCP server keeps disconnecting / "Couldn't finish loading" / WebSocket closes with code 1006.**
The VPN's `tun0` MTU of 1500 can cause fragmentation on long-lived WebSocket connections. `entrypoint.sh` already lowers it to 1400 right after the interface comes up.

**"Your sign-in won't be saved on this device" / `safeStorage not available` in logs.**
This is fixed. `entrypoint.sh` launches the GUI app inside `dbus-run-session` with a `gnome-keyring-daemon` unlocked/started beforehand, so `org.freedesktop.secrets` is reachable and Electron's `safeStorage` can encrypt tokens normally. If you still see this warning, check `claude-desktop-unofficial --doctor` — the `Keyring` line should read `PASS ... org.freedesktop.secrets reachable`. If it doesn't, `docker exec -it claude-desktop-vpn ps aux | grep gnome-keyring` to confirm the daemon actually started.

**Microphone doesn't work / `pactl` says "Connection refused".**
Make sure `PULSE_SERVER` is set to `unix:/mnt/wslg/runtime-dir/pulse/native` (not the nonexistent `/mnt/wslg/PulseServer`) and that only `/mnt/wslg/runtime-dir` is mounted — not all of `/mnt/wslg` (see next point).

**Don't mount all of `/mnt/wslg`.**
`/mnt/wslg/distro/` bind-mounts the *entire root filesystem* of the WSLg host distro, which — because Windows drives are mounted via `drvfs` — includes your Windows drives. `run.sh` only mounts `/mnt/wslg/runtime-dir`, which is all that's actually needed for Wayland/PulseAudio sockets.

**AdGuard login keeps being requested again on every run.**
AdGuard ties the session to the device's MAC address and hostname. Docker randomizes both per container by default. `run.sh` generates a random MAC once and stores it in `<home>/.container-mac`, reusing it on every run, and `entrypoint.sh`/`run.sh` fix the hostname to `claude-desktop-vpn-container`. Don't delete the `.container-mac` file.

**`adguardvpn-cli connect` fails with `Insufficient rights, please try running the command with sudo -E` / `ioctl TUNSETIFF failed: Operation not permitted`.**
The VPN process needs to create a TUN device, which requires root privileges — it must run as root inside the container (the image is deliberately structured this way: VPN login/connect always run as root; only the GUI app drops to the unprivileged `claude` user).

**`adguardvpn-cli status` shows "System DNS could not be configured. DNS queries may bypass the VPN tunnel".**
This is expected and not a leak in this setup. Docker manages `/etc/resolv.conf` itself, so AdGuard can't rewrite it — but the killswitch only allows traffic from root (uid 0) or through `tun0`; since AdGuard's AUTO routing mode installs a full default route via `tun0`, DNS queries (like everything else from non-root processes) are forced through the tunnel regardless of which nameserver IP is configured. Verify anytime with `docker exec -it claude-desktop-vpn curl ip-api.com` — it should report the VPN's location, not your real one.

## Known limitations

- No KVM/QEMU passthrough, so Claude Desktop's Cowork VM feature won't work inside the container (`--doctor` will report this).
- UDP traffic is fully tunneled (this setup uses the CLI's TUN mode, not a TCP-only SOCKS proxy), but DNS resolution depends on what AdGuard's client configures — check `adguardvpn-cli config show` if you need to verify.
