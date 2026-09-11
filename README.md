# Claude Desktop in a Proxy-Isolated Docker Container (WSL2 / Linux)

**Built and tested for Windows + WSL2**, with best-effort support for native Linux desktops — `run.sh` auto-detects WSLg (`/mnt/wslg`) vs. a native `XDG_RUNTIME_DIR` and mounts the right GUI/audio sockets accordingly (see [How it works](#how-it-works)). It does **not** support macOS: there's no X11/Wayland or PulseAudio on the host to pass through, and it would need a fundamentally different approach (e.g. VNC).

Runs [Claude Desktop](https://github.com/aaddrick/claude-desktop-debian) inside a Docker container with **all traffic forced through a proxy you provide** (HTTP, HTTPS, or SOCKS5, with or without authentication) and a **killswitch** — if the proxy drops, the container loses network access entirely instead of leaking traffic through your regular connection. GUI, audio, and microphone are forwarded to Windows via WSLg (see [How it works](#how-it-works) for details).

## How it works

- The container has its own isolated network namespace (unlike separate WSL2 distros, which share one).
- `entrypoint.sh` sets a default-DROP `iptables` policy, brings up [sing-box](https://github.com/SagerNet/sing-box) in TUN mode (which routes all system traffic into a `tun0` interface and forwards it to your configured HTTP/HTTPS/SOCKS5 proxy), waits for `tun0`, then allows traffic only through it (plus loopback and the sing-box process itself, which needs to reach your actual proxy server).
- If the proxy tunnel never comes up, the container refuses to start the GUI app instead of running with a broken killswitch.
- GUI is displayed via X11 (`/tmp/.X11-unix`, bind-mounted from the host — the app runs in X11-via-XWayland mode, see `--doctor` output). Audio and microphone go through PulseAudio, whose socket `run.sh` locates automatically: `/mnt/wslg/runtime-dir/pulse/native` on WSL2 (provided by WSLg), or `$XDG_RUNTIME_DIR/pulse/native` on native Linux (provided by the desktop session).
- Your home directory is stored outside the container (bind-mounted from the host), so it survives container restarts. The container itself is ephemeral — it only exists while the main process (Claude Desktop) is running.

## Prerequisites

**On WSL2:**
- **Windows 11** with WSL2 and a Linux distro (tested on Debian).
- **`.wslconfig` must use NAT networking**, not mirrored:
```ini
  [wsl2]
  networkingMode=NAT
```
  (Mirrored mode breaks Docker's bridge networking on some setups — see Troubleshooting.)

**On native Linux:**
- An X11 (or XWayland) session — `$DISPLAY` and `/tmp/.X11-unix` must be present.
- A running PulseAudio user session (`$XDG_RUNTIME_DIR/pulse/native` must exist) if you want audio/mic.
- Not tested as extensively as WSL2 — see [How it works](#how-it-works) for what `run.sh` auto-detects.

**Both:**
- **Docker Engine** (not Docker Desktop). On WSL2, install it inside the distro:
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
- An **HTTP, HTTPS, or SOCKS5 proxy** to route traffic through, with or without a username/password.

Node.js is installed in the image alongside the packages above because `claude-desktop-unofficial` depends on it. The .NET 10 SDK is also installed, in case you want to build .NET projects inside the same proxied environment (e.g. via `--mount` — see [Mounting host folders](#mounting-your-windows-drives)) — change `dotnet-sdk-10.0` in the `Dockerfile` if you need a different version.

## Project files

```
~/claude-desktop-proxy-container/
├── Dockerfile     # image definition
├── entrypoint.sh  # killswitch + sing-box bring-up + GUI launch, runs as container PID 1
├── run.sh         # wrapper around docker run with the right flags
└── README.md
```

## Setup

1. Clone/create the project directory and add `Dockerfile`, `entrypoint.sh`, `run.sh` (see repo).
2. Build the image:
```bash
   cd ~/claude-desktop-proxy-container
   docker build --network=host -t claude-desktop-proxy-container \
       --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) .
```
   `--network=host` is required for the build itself — some WSL2/Docker setups fail to resolve DNS over the default bridge network during `docker build` (see Troubleshooting). It has no effect on the container at runtime.

   By default this reuses Docker's build cache, including the `claude-desktop-unofficial` install step — a plain rebuild won't pick up a newer upstream release on its own. `entrypoint.sh` checks for a newer version on every container start and logs a warning if one's available; when you see that warning, force just that step (and everything after it) to re-run:
```bash
   docker build --network=host -t claude-desktop-proxy-container \
       --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) \
       --build-arg CACHEBUST=$(date +%s) .
```

3. Pick a home directory for the container (anything you like, created automatically):
```bash
   mkdir -p ~/claude-container-home
```

## Proxy config

Create a file with your proxy URL:

```bash
echo 'socks5://user:pass@proxy.example.com:1080' > ~/claude-proxy.conf
```

Supported schemes are `socks5://`, `http://` and `https://` (an HTTP-proxy protocol carried over TLS to the proxy server itself — common with paid proxy providers); the `user:pass@` part is optional if your proxy doesn't require authentication. This file is bind-mounted read-only into the container at runtime and never baked into the image — keep it wherever you keep other credentials, and pass its path via `--proxy-path`.

The file can hold several proxies, one per line — `entrypoint.sh` uses the **first line that isn't blank and doesn't start with `#`**, so you keep spares around and switch by commenting/uncommenting:

```
# home proxy
socks5://user:pass@proxy1.example.com:1080
# backup proxy
#socks5://user:pass@proxy2.example.com:1080
```

Here `proxy1` is active. Comment it out and uncomment `proxy2` to switch — no need to edit `run.sh` or rebuild anything, just restart the container.

## Normal usage

```bash
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf
```

With no trailing command, this launches `claude-desktop-unofficial` (the GUI) directly. The container:
1. Sets up the killswitch.
2. Checks whether a newer `claude-desktop-unofficial` package is available upstream and logs a warning if so (informational only, never blocks startup — rebuild the image to pick up the update).
3. Generates a [sing-box](https://github.com/SagerNet/sing-box) config from the proxy file and brings up its TUN interface, waiting (up to 30s) for `tun0`.
4. If the tunnel fails to come up, the container **exits** rather than launching the GUI in a broken state — check `docker exec -it claude-desktop-proxy tail -40 /var/log/sing-box.log`.
5. Launches Claude Desktop with GUI/audio/mic forwarded to your Windows session.

Closing the Claude Desktop window doesn't necessarily stop the container — like on native Linux, the app may keep running in the background. To fully stop everything:

```bash
docker rm -f claude-desktop-proxy
```

### Mounting your Windows drives

By default the container only sees `$HOME_DIR` — none of your actual Windows drives. If you need Claude Desktop to access files elsewhere on `C:`, `D:`, etc., pass `--mount-wsl-drives`:

```bash
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf --mount-wsl-drives
```

This bind-mounts every `/mnt/<letter>` drive WSL2 exposes (e.g. `/mnt/c`, `/mnt/d`) into the container at the same path. It's a no-op with a warning if you're not on WSL2 (native Linux has no drive letters to mount). **This gives the container read/write access to your entire Windows filesystem** — only use it if you actually need it, and understand it works against the isolation this setup is otherwise built for.

If you only need specific folders rather than whole drives, use `--mount src-path:dst-path` instead — it can be repeated for multiple folders:

```bash
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf \
    --mount /mnt/e/git/some-project:/home/claude/some-project \
    --mount /mnt/d/docs:/home/claude/docs
```

Note that `~` in the destination gets expanded by your *host* shell before `run.sh` ever sees it (e.g. `~/test` becomes `/home/<you>/test`, not a path inside the container) — write out the actual in-container path you want (typically under `/home/claude/...`) instead of relying on `~`.

### Forwarding ports

By default nothing running inside the container is reachable from the host. If you're running something inside the container that needs to be reachable (a dev server, an API, etc.), use `--port [host-ip:]host-port:container-port` — it can be repeated, takes an optional `/tcp` or `/udp` suffix (default `/tcp`), and an optional host IP to bind to a specific interface instead of all of them:

```bash
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf \
    --port 3000:3000 \
    --port 127.0.0.1:8080:80 \
    --port 53:53/udp \
    bash
```

This is a regular Docker port publish (`-p`) — the killswitch only restricts *outbound* traffic (`OUTPUT` chain), so published ports work normally regardless of the tunnel/killswitch state.

### Using your host's SSH agent

On by default: `run.sh` forwards your host's `$SSH_AUTH_SOCK`, plus `~/.ssh/config` (read-only) and `~/.ssh/known_hosts` (read-write) if they exist. No other files under `~/.ssh` are touched. No-op with a warning if there's no `ssh-agent` running on the host.

To turn it all off at once:

```bash
~/claude-desktop-vpn-container/run.sh --home ~/claude-container-home/ --location SG --no-forward-ssh-agent bash
```

Note this is why `gnome-keyring-daemon` is started with `--components=secrets,pkcs11` (no `ssh`) in `entrypoint.sh`: gnome-keyring's own `ssh` component would otherwise claim `SSH_AUTH_SOCK` for its own (empty, keyless) agent and shadow the one forwarded from the host.

### Running other commands in the container

Since `run.sh` accepts a trailing command, you can use the same proxied environment for other things:

```bash
# doctor diagnostics
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf claude-desktop-unofficial --doctor

# quick connectivity check
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf curl ip-api.com

# shell access
~/claude-desktop-proxy-container/run.sh --home ~/claude-container-home/ --proxy-path ~/claude-proxy.conf bash
```

### Inspecting a running container

```bash
docker ps -a                            # see if it's running
docker exec -it claude-desktop-proxy bash # shell into a running container
```

## Troubleshooting

**`docker build` hangs or times out resolving DNS.**
Rebuild with `--network=host`. If `apt-get` inside the Dockerfile hangs specifically (not fails), it's usually an IPv6 connectivity gap in WSL2 — the Dockerfile already forces IPv4 via `Acquire::ForceIPv4=true` and `curl -4`.

**Docker containers have no network access at all (build or runtime), even though the WSL2 host does.**
Check `.wslconfig` — if `networkingMode=mirrored`, switch to `NAT` (see Prerequisites) and `wsl --shutdown`, then restart Docker. Mirrored mode has been observed to break Docker's bridge/NAT forwarding on some Windows builds. If NAT is already set, check `sudo iptables -t nat -L -n -v | grep -i docker` for a `MASQUERADE` rule — if it's missing, `sudo systemctl restart docker` regenerates it (this can happen if another WSL2 distro touches iptables after Docker starts, since all WSL2 distros share one network namespace).

**Outbound requests intermittently hang for ~5s then succeed, or fail with "HTTP protocol error".**
Some networks have broken/unreliable IPv6 — a request tries IPv6 first, stalls, then falls back to IPv4. Pass `--disable-ipv6` to `run.sh` to disable IPv6 inside the container (`--sysctl net.ipv6.conf.all.disable_ipv6=1`), e.g. `run.sh --home ... --proxy-path ~/claude-proxy.conf --disable-ipv6`. Confirm it's active with `docker exec -it claude-desktop-proxy sysctl net.ipv6.conf.all.disable_ipv6` (should read `1`).

**Claude Desktop window is blank / doesn't render / can't be dragged.**
This was Docker's default 64MB `/dev/shm`, too small for Chromium's multi-process rendering. Already fixed via `--shm-size=1g` in `run.sh` — if you removed that flag, add it back.

**MCP server keeps disconnecting / "Couldn't finish loading" / WebSocket closes with code 1006.**
The tunnel's `tun0` MTU of 1500 can cause fragmentation on long-lived WebSocket connections. `entrypoint.sh` already lowers it to 1400 right after the interface comes up.

**"Your sign-in won't be saved on this device" / `safeStorage not available` in logs.**
`entrypoint.sh` does launch the GUI inside `dbus-run-session` with a `gnome-keyring-daemon` unlocked/started beforehand — but in practice the `DBUS_SESSION_BUS_ADDRESS` env var doesn't reliably survive the several layers of the `claude-desktop-unofficial` launcher script between that setup and the actual Electron binary being exec'd, so the app can end up talking to a *different*, never-unlocked, D-Bus-auto-activated keyring instead of the one we unlocked.

Rather than chase that down further, `entrypoint.sh` sidesteps it: on first run it writes `CLAUDE_PASSWORD_STORE=basic` to `~/.config/claude-desktop-debian/environment` (the launcher's own documented config file, read before every launch) if that file doesn't already exist. This makes the launcher pass `--password-store=basic` to Electron, which stores credentials in plain form instead of going through the OS keyring at all — sidestepping the D-Bus dependency entirely rather than fixing it. **Trade-off:** the login token is then stored unencrypted on disk (still only as exposed as the rest of `$HOME_DIR`, which is already bind-mounted from your host). Delete the `environment` file (or edit out that line) if you'd rather keep chasing the keyring path instead.

To confirm which one is actually active, check the running process's own arguments rather than logs:
```bash
docker exec -it claude-desktop-vpn pgrep -af claude-desktop-unofficial
```
Look for `--password-store=basic` on the main `claude-desktop` process line (not the `bash /usr/bin/claude-desktop-unofficial` wrapper line).

**Microphone doesn't work / `pactl` says "Connection refused".**
Check what `run.sh` detected: it prints a warning if the runtime dir it picked (`/mnt/wslg/runtime-dir` on WSL2, `$XDG_RUNTIME_DIR` on native Linux) doesn't exist on the host. Confirm the actual Pulse socket is there (`ls <runtime-dir>/pulse/native`) and, on WSL2, that you're not using the nonexistent `/mnt/wslg/PulseServer` path from older guides.

**Don't mount all of `/mnt/wslg` (WSL2 only).**
`/mnt/wslg/distro/` bind-mounts the *entire root filesystem* of the WSLg host distro, which — because Windows drives are mounted via `drvfs` — includes your Windows drives. `run.sh` only mounts `/mnt/wslg/runtime-dir`, which is all that's actually needed for Wayland/PulseAudio sockets.

**`sing-box run` fails with `operation not permitted` / can't create the TUN device.**
sing-box needs to create a TUN device, which requires root privileges and `NET_ADMIN` — it must run as root inside the container (the image is deliberately structured this way: `entrypoint.sh` starts sing-box as root before the killswitch drops privileges for the GUI app, which runs as the unprivileged `claude` user). Confirm `run.sh` still passes `--cap-add=NET_ADMIN --device=/dev/net/tun` — both are required.

**"tun0 did not come up" / container exits immediately.**
Check the log: `docker exec -it claude-desktop-proxy tail -40 /var/log/sing-box.log`. Common causes: the proxy file's URL is malformed (must be `socks5://`, `http://` or `https://`, with a resolvable host and a port), the proxy server is unreachable from the container (the killswitch allows root's own outbound traffic, so sing-box itself can always reach out to dial the proxy — if that dial fails, the proxy server itself is the problem), or the proxy requires auth but the file has no `user:pass@`.

**Everything fails — even `curl -4 <raw-ip>` — and `/var/log/sing-box.log` repeats `DNS query loopback in transport[proxy-dns]`.**
This means your proxy is given as a **hostname**, not a bare IP, in the proxy file. sing-box needs to resolve that hostname before it can even open a connection to the proxy — but if DNS resolution itself is routed through the proxy, you get a deadlock (to reach the proxy you must resolve it, to resolve anything you must already be able to reach the proxy). `entrypoint.sh`'s generated config avoids this by resolving the proxy's own hostname through a separate direct (non-tunneled) DNS lookup (`dns-direct`, only ever used for the proxy's own address) while all other DNS still goes through the tunnel — this is already fixed as of the current `entrypoint.sh`; if you still see this, you're running an image built from an older copy of it and need to rebuild (see below).

**DNS queries / "who am I" checks show your real location instead of the proxy's.**
Docker manages `/etc/resolv.conf` itself, so sing-box can't rewrite it — but the killswitch only allows traffic from root (uid 0) or through `tun0`, and sing-box's `auto_route` installs a full default route via `tun0` plus its own DNS resolution routed through the proxy (see the `dns` section of the generated config), so DNS from the unprivileged `claude` user is forced through the tunnel regardless of the nameserver IP configured. Verify anytime with `docker exec -it claude-desktop-proxy curl ip-api.com` — it should report your proxy's location, not your real one.

## Known limitations

- No KVM/QEMU passthrough, so Claude Desktop's Cowork VM feature won't work inside the container (`--doctor` will report this).
- If your proxy is `http://` or `https://`, UDP traffic cannot be tunneled through it — HTTP proxies only support `CONNECT` for TCP. Use a `socks5://` proxy if you need UDP to work (and the SOCKS5 server itself must support `UDP ASSOCIATE`).
