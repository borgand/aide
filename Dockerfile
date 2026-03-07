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

# ── GitHub CLI (gh) ──────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
       https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── GitLab CLI (glab) ─────────────────────────────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && GLAB_VERSION=$(curl -fsSL https://api.github.com/repos/gitlab-org/cli/releases/latest \
       | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/') \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" \
       -o /tmp/glab.deb \
    && dpkg -i /tmp/glab.deb \
    && rm /tmp/glab.deb

# ── Kubernetes tooling ────────────────────────────────────────────────────────
RUN ARCH=$(dpkg --print-architecture) \
    && KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
       -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR=/usr/local/bin bash

RUN ARCH=$(dpkg --print-architecture) \
    && KZ_VERSION=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest \
       | grep '"tag_name"' | grep kustomize | head -1 \
       | sed 's/.*"kustomize\/v\([^"]*\)".*/\1/') \
    && curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KZ_VERSION}/kustomize_v${KZ_VERSION}_linux_${ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin kustomize \
    && chmod +x /usr/local/bin/kustomize

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
    && useradd -m -u 1000 -g aide -s /usr/bin/zsh aide \
    && mkdir -p /home/aide/.ssh \
    && chmod 700 /home/aide/.ssh \
    && chown aide:aide /home/aide/.ssh

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
RUN npm config set prefix '/home/aide/.local' \
    && curl -fsSL https://claude.ai/install.sh | bash

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
