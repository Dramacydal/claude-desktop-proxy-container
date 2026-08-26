FROM debian:bookworm-slim

ARG PUID=1000
ARG PGID=1000

RUN apt-get update -o Acquire::ForceIPv4=true && apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    iptables \
    iproute2 \
    sudo \
    dbus-x11 \
    gnome-keyring \
    libsecret-1-0 \
    pulseaudio-utils \
    libnss3 \
    libgtk-3-0 \
    libxss1 \
    libasound2 \
    fonts-liberation \
    dbus-user-session \
    libglib2.0-bin \
    && rm -rf /var/lib/apt/lists/*

RUN curl -4 -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y -o Acquire::ForceIPv4=true nodejs && \
    rm -rf /var/lib/apt/lists/*

ENV USER=root
RUN curl -4 -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/master/scripts/release/install.sh -o /tmp/install-adguard.sh
RUN sh /tmp/install-adguard.sh -v < /dev/null || true
RUN ln -sf /opt/adguardvpn_cli/adguardvpn-cli /usr/local/bin/adguardvpn-cli

RUN curl -4 -fsSL https://pkg.claude-desktop-debian.dev/KEY.gpg | gpg --dearmor -o /usr/share/keyrings/claude-desktop-unofficial.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/claude-desktop-unofficial.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
        > /etc/apt/sources.list.d/claude-desktop-unofficial.list && \
    apt-get update -o Acquire::ForceIPv4=true && apt-get install -y -o Acquire::ForceIPv4=true --no-install-recommends claude-desktop-unofficial && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -g ${PGID} claude && \
    useradd -u ${PUID} -g ${PGID} -m -s /bin/bash claude && \
    usermod -aG sudo claude && \
    passwd -d claude && \
    echo "claude ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude-desktop-unofficial"]
