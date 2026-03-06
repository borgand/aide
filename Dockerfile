FROM debian:bookworm-slim

ARG GO_VERSION=1.23.6
ARG DELTA_VERSION=0.18.2

# ── Corporate CA certificates (optional, for MITM proxy environments) ────────
# Drop .crt/.pem files in certs/ or set EXTRA_CA_CERT_B64 build arg.
COPY certs/ /tmp/extra-certs/
ARG EXTRA_CA_CERT_B64=""
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && if [ -n "$EXTRA_CA_CERT_B64" ]; then \
         echo "$EXTRA_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/corporate-ca.crt; \
       fi \
    && for f in /tmp/extra-certs/*.crt /tmp/extra-certs/*.pem /tmp/extra-certs/*.cer; do \
         [ -f "$f" ] && cp "$f" /usr/local/share/ca-certificates/"$(basename "$f" | sed 's/\.\(pem\|cer\)$/.crt/')"; \
       done; true \
    && update-ca-certificates \
    && rm -rf /tmp/extra-certs

# ── System packages (single layer) ──────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      gnupg \
      git \
      jq \
      zsh \
      fzf \
      iptables \
      ipset \
      iproute2 \
      dnsutils \
      socat \
      openssh-client \
      python3 \
      python3-venv \
      pipx \
      gosu \
      procps \
      less \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js 22.x via NodeSource ─────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Go from official tarball ─────────────────────────────────────────────────
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
    | tar -C /usr/local -xz

# ── Docker CLI only ──────────────────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# ── git-delta ────────────────────────────────────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then DELTA_ARCH="amd64"; \
       elif [ "$ARCH" = "arm64" ]; then DELTA_ARCH="arm64"; \
       else DELTA_ARCH="$ARCH"; fi \
    && curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${DELTA_ARCH}.deb" \
       -o /tmp/delta.deb \
    && dpkg -i /tmp/delta.deb \
    && rm /tmp/delta.deb

# ── Playwright system dependencies (as root) ─────────────────────────────────
RUN npx playwright install-deps chromium

# ── Non-root user (NO sudoers) ───────────────────────────────────────────────
RUN groupadd -g 1000 aide \
    && useradd -m -u 1000 -g aide -s /usr/bin/zsh aide

# ── Copy scripts ─────────────────────────────────────────────────────────────
COPY entrypoint.sh init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh
COPY settings.json /etc/aide/policy.json
COPY statusline.py /usr/local/bin/aide-statusline
RUN chmod +x /usr/local/bin/aide-statusline

# ── Environment ──────────────────────────────────────────────────────────────
ENV ANTHROPIC_BASE_URL=https://api.anthropic.com \
    PLAYWRIGHT_BROWSERS_PATH=/home/aide/.cache/ms-playwright \
    DEVCONTAINER=true \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PATH="/home/aide/.local/bin:/usr/local/go/bin:${PATH}"

# ── Switch to aide for user-space installs ───────────────────────────────────
USER aide
WORKDIR /home/aide

# Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash

# Playwright browsers (as aide user)
RUN npx playwright install chromium

# Zsh setup with plugins
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/latest/download/zsh-in-docker.sh)" -- \
    -p git \
    -p fzf

# ── Switch back to root for entrypoint ───────────────────────────────────────
USER root
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
