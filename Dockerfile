# ==========================================================================
# aide — Claude Code in a secured Docker container
# Multi-stage build with mise for tool version management
# ==========================================================================

FROM debian:bookworm-slim AS base

# --- Layer 0: CA certificates (optional) ---
COPY certs/ /tmp/extra-certs/
ARG EXTRA_CA_CERT_B64=""
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && if [ -n "$EXTRA_CA_CERT_B64" ]; then \
         echo "$EXTRA_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/corporate-ca.crt; \
       fi \
    && for f in /tmp/extra-certs/*.crt /tmp/extra-certs/*.pem /tmp/extra-certs/*.cer; do \
         [ -f "$f" ] && cp "$f" /usr/local/share/ca-certificates/"$(basename "$f" | sed 's/\.\(pem\|cer\)$/.crt/')"; \
       done; true \
    && update-ca-certificates \
    && rm -rf /tmp/extra-certs

# --- Layer 1: System packages ---
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl git jq socat gosu inotify-tools gnupg \
       iptables ipset dnsutils \
       bash fzf procps \
       python3 \
    && rm -rf /var/lib/apt/lists/*

# --- Layer 2: Docker CLI (signed APT repo) ---
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
       https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# --- Layer 3: Non-root user ---
RUN groupadd -g 1000 aide \
    && useradd -m -u 1000 -g aide -s /bin/bash aide \
    && mkdir -p /home/aide/.ssh /home/aide/.kube \
    && chmod 700 /home/aide/.ssh \
    && chown -R aide:aide /home/aide/.ssh /home/aide/.kube

# ======================================================================
# Builder stages — each installs a group of tools via mise
# ======================================================================

FROM base AS mise-runtimes
RUN curl -fsSL https://mise.jdx.dev/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
COPY mise/runtimes.toml /tmp/mise/.mise.toml
RUN cd /tmp/mise && mise install --yes

FROM base AS mise-cli-tools
RUN curl -fsSL https://mise.jdx.dev/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
COPY mise/cli-tools.toml /tmp/mise/.mise.toml
COPY mise/cli-tools.lock /tmp/mise/mise.lock
RUN cd /tmp/mise && mise trust && mise install --locked

FROM base AS mise-apps
RUN curl -fsSL https://mise.jdx.dev/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
COPY mise/apps.toml /tmp/mise/.mise.toml
RUN cd /tmp/mise && mise install --yes

# ======================================================================
# Final stage — assemble from builders
# ======================================================================

FROM base AS final

# --- Copy tool installations from builder stages ---
COPY --from=mise-runtimes /root/.local/share/mise/installs/node/ /usr/local/lib/node/
COPY --from=mise-runtimes /root/.local/share/mise/installs/go/   /usr/local/go/
COPY --from=mise-cli-tools /root/.local/share/mise/installs/ /usr/local/share/mise-tools/
COPY --from=mise-apps /root/.local/share/mise/installs/ /usr/local/share/mise-apps/

# --- Symlink binaries into PATH ---
# node: create a stable 'current' symlink to the versioned dir so npm's
# wrapper script can resolve node_modules relative to its own location.
RUN node_dir=$(find /usr/local/lib/node/ -maxdepth 1 -mindepth 1 \
                 -not -type l -type d | head -1) \
    && ln -sf "$node_dir" /usr/local/lib/node/current \
    && find /usr/local/go/ -name "go" -type f \
         -exec ln -sf {} /usr/local/bin/go \; \
    && for tool in kubectl helm kustomize glab delta; do \
         find /usr/local/share/mise-tools/ -name "$tool" -type f \
           -exec ln -sf {} /usr/local/bin/"$tool" \; ; \
       done \
    && find /usr/local/share/mise-apps/ -name "claude" \( -type f -o -type l \) \
         -exec ln -sf {} /usr/local/bin/claude \; \
    && chmod +x /usr/local/bin/claude 2>/dev/null || true

# --- GitHub CLI (direct download; bypasses mise/aqua attestation check blocked by corporate firewalls) ---
ARG GH_VERSION=2.68.1
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
         -o /tmp/gh.tar.gz \
    && case "$ARCH" in \
         arm64) echo "018461fc2d55e88ff4e65d34251a8e3742629f44564a9734512276c080316f8f  /tmp/gh.tar.gz" | sha256sum -c - ;; \
         amd64) echo "b4f533bf21d1fc0750976b4755e479ae3f59bfc42c9c22dfb0c0c5491ab1e152  /tmp/gh.tar.gz" | sha256sum -c - ;; \
       esac \
    && tar -xz -f /tmp/gh.tar.gz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_${ARCH}

# --- Playwright system deps (must run as root, after node is available) ---
RUN npx --yes playwright install-deps chromium 2>/dev/null || true

# --- Environment variables ---
ENV ANTHROPIC_BASE_URL=https://api.anthropic.com \
    DISABLE_AUTOUPDATER=1 \
    PLAYWRIGHT_BROWSERS_PATH=/home/aide/.cache/ms-playwright \
    DEVCONTAINER=true \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PATH="/home/aide/.local/bin:/usr/local/lib/node/current/bin:/usr/local/go/bin:/usr/local/bin:${PATH}"

# --- Stub mise so npm's reshim hook doesn't fail during build ---
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/mise && chmod +x /usr/local/bin/mise

# --- User-space installs (as aide user) ---
USER aide
RUN npm config set prefix '/home/aide/.local' \
    && npm install -g "@playwright/mcp" \
    && npx playwright install chromium

# --- Remove build-time mise stub and switch back to root for entrypoint ---
USER root
RUN rm /usr/local/bin/mise
COPY entrypoint.sh init-firewall.sh /usr/local/bin/
COPY statusline.py /usr/local/bin/aide-statusline
COPY settings.json /etc/aide/settings-policy.json
COPY mcp-defaults.json /etc/aide/mcp-defaults.json
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh /usr/local/bin/aide-statusline

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD pgrep -u aide claude || exit 1

WORKDIR /workspace
ENTRYPOINT ["entrypoint.sh"]
CMD ["claude"]
