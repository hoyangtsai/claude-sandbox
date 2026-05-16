# openab sandbox base image.
# The Rust toolchain (and Node) is layered on by devcontainer Features; this
# Dockerfile only provides the firewall tooling, dev CLIs, and non-root user.
FROM mcr.microsoft.com/devcontainers/base:debian

# Firewall tooling (iptables, ipset, dig) + everyday dev CLIs.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        ripgrep \
        fzf \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install the network firewall script and let the non-root user run it via
# sudo without a password (postStartCommand invokes it on every start).
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && echo 'vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh' \
        > /etc/sudoers.d/init-firewall \
    && chmod 0440 /etc/sudoers.d/init-firewall

# Pre-create the volume mountpoints owned by the non-root user so that the
# fresh named volumes inherit vscode ownership instead of root.
RUN mkdir -p /home/vscode/.claude /commandhistory \
    && chown -R vscode:vscode /home/vscode/.claude /commandhistory

# Persist bash history into the mounted /commandhistory volume.
RUN printf '%s\n' \
        'export HISTFILE=/commandhistory/.bash_history' \
        'export PROMPT_COMMAND="history -a"' \
        >> /home/vscode/.bashrc
