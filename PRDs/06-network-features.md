# PRD-06: Network Features

## Overview

aide supports several network features that bridge the container's isolated network to the host's network services: SSH agent forwarding, Docker socket passthrough, Kubernetes local cluster access, and arbitrary LAN host proxying. All features are implemented using socat proxies rather than DNAT, because Debian bookworm's nf_tables backend does not reliably support DNAT of loopback-destined traffic.

## Requirements

- **FR-06-01** SSH agent keys MUST be forwarded into the container without copying the private key.
- **FR-06-02** Docker socket passthrough MUST support direct socket paths and a `rancher` preset.
- **FR-06-03** Local Kubernetes clusters (bound to `127.0.0.1`) MUST be accessible from inside the container.
- **FR-06-04** LAN hosts (mDNS names, VPN hostnames) MUST be proxied through the Docker bridge.
- **FR-06-05** socat proxies MUST bind to a specific host IP, never to `0.0.0.0`.
- **FR-06-06** Host IP auto-detection MUST handle Lima SLIRP networking on macOS.
- **FR-06-07** Kubeconfig server URLs MUST be rewritten to point to `127.0.0.1:<proxy_port>` before mounting.
- **FR-06-08** All proxy processes MUST be killed on `aide` exit.

## Design

### Architecture

```
Host (bin/aide)                        Container (entrypoint.sh)
─────────────────────────────────────  ───────────────────────────────────
SSH agent (Unix socket)
  └─ socat TCP-LISTEN:<ssh_port>          socat UNIX-LISTEN:/tmp/ssh_agent.sock
     bind=<bridge_ip>                       TCP:host.docker.internal:<ssh_port>
     → UNIX-CONNECT:$SSH_AUTH_SOCK        SSH_AUTH_SOCK=/tmp/ssh_agent.sock

Local K8s (127.0.0.1:<kube_port>)
  └─ socat TCP-LISTEN:<proxy_port>        socat TCP-LISTEN:<proxy_port>
     bind=<bridge_ip>                       bind=127.0.0.1
     → TCP:127.0.0.1:<kube_port>           → TCP:host.docker.internal:<proxy_port>

LAN host (<lan_ip>:<lan_port>)
  └─ socat TCP-LISTEN:<proxy_port>        socat TCP-LISTEN:<lan_port>
     bind=<bridge_ip>                       bind=127.0.0.1
     → TCP:<lan_ip>:<lan_port>             → TCP:host.docker.internal:<proxy_port>
                                           /etc/hosts: 127.0.0.1 <lan_domain>
```

### Host IP Detection

All host-side socat proxies bind to a specific host interface to avoid LAN exposure. The bind IP (`socat_bind_ip`) is determined in this priority order:

1. `--host-ip` CLI flag
2. `host_ip:` in `aide.yaml`
3. Auto-detection:
   - **macOS:** Resolve `host.docker.internal`; verify it's a local interface with `ifconfig`. If it's not a local interface (Lima SLIRP case), fall back to `127.0.0.1`.
   - **Linux:** Read Docker bridge gateway from `docker network inspect bridge`, then fall back to reading `docker0` address from `ip addr`.
4. Final fallback: `172.17.0.1` (Linux default docker0 gateway)

**Lima SLIRP networking (macOS):**
When using Lima-based Docker runtimes (Rancher Desktop, OrbStack in Lima mode), `host.docker.internal` resolves to a SLIRP-managed IP that is visible from inside the Lima VM but is not a local interface on macOS. Binding socat to this IP fails silently. The fix is to detect this case and fall back to `127.0.0.1`: Lima routes container traffic from the VM to macOS loopback.

```bash
if [[ "$(uname -s)" == "Darwin" ]]; then
  socat_bind_ip=$(python3 -c \
    "import socket; print(socket.gethostbyname('host.docker.internal'))" 2>/dev/null || true)
  # Check if this IP is a local interface
  if [[ -n "$socat_bind_ip" ]] && ! ifconfig 2>/dev/null | grep -qF "inet ${socat_bind_ip}"; then
    echo "aide: info: host.docker.internal resolves to ${socat_bind_ip} but is not a local interface; Lima SLIRP detected"
    socat_bind_ip=""
  fi
  [[ -z "$socat_bind_ip" ]] && socat_bind_ip="127.0.0.1"
fi
```

**Pitfall:** Never fall back to `0.0.0.0`. Binding socat to `0.0.0.0` exposes proxies on the LAN, allowing other machines to reach the host's SSH agent or local Kubernetes API server.

### SSH Agent Forwarding

**Linux:** Bind-mount the Unix socket directly:
```bash
docker_flags+=(-v "$SSH_AUTH_SOCK:/tmp/ssh_agent.sock" -e "SSH_AUTH_SOCK=/tmp/ssh_agent.sock")
```

**macOS:** Docker Desktop and Rancher Desktop run in a Linux VM. The macOS filesystem is shared into the VM via 9p/virtiofs, which does not support Unix domain sockets. Bind-mounting `$SSH_AUTH_SOCK` into the container will fail silently (the socket exists but connections fail). Use a socat TCP bridge:

Host side:
```bash
ssh_proxy_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
socat TCP-LISTEN:"$ssh_proxy_port",bind="${socat_bind_ip}",reuseaddr,fork UNIX-CONNECT:"$SSH_AUTH_SOCK" &
docker_flags+=(-e "SSH_AGENT_PROXY_PORT=$ssh_proxy_port")
```

Container side (in `entrypoint.sh`):
```bash
socat UNIX-LISTEN:/tmp/ssh_agent.sock,fork,user=aide,group=aide,mode=600 \
  TCP:host.docker.internal:"$SSH_AGENT_PROXY_PORT" &
export SSH_AUTH_SOCK=/tmp/ssh_agent.sock
```

The Unix socket permissions (`user=aide,group=aide,mode=600`) ensure only the `aide` user can connect.

### Docker Socket Passthrough

The Docker socket GID varies by runtime:
- Native Linux Docker: GID 999 or similar (distro-dependent)
- Docker Desktop (macOS): GID 0 (root-owned)
- Rancher Desktop (Lima): GID 102 or similar

`entrypoint.sh` handles the GID dynamically (see PRD-03). Socket path resolution (including the `rancher` preset and the macOS virtiofs pitfall) is in `bin/aide` — see PRD-04 `resolve_docker_socket()`.

### Kubernetes Local Cluster Access

Local Kubernetes clusters (k3s, Rancher Desktop's k8s, minikube) typically bind their API server to `127.0.0.1`. From inside the container, `127.0.0.1` is the container's loopback — not the host. A two-hop socat proxy bridges them:

**Step 1 (host side, `bin/aide`):**
1. Extract the cluster server URL from the kubeconfig: `kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'`
2. If the URL is `localhost` or `127.0.0.1`, it's a local cluster.
3. Allocate an ephemeral port: `python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'`
4. Rewrite the kubeconfig server URL to `https://127.0.0.1:<proxy_port>` in a temp copy.
5. Start host-side socat: `socat TCP-LISTEN:<proxy_port>,bind=<bridge_ip>,reuseaddr,fork TCP:127.0.0.1:<kube_port>`
6. Pass `AIDE_KUBE_LOCAL_PORT=<proxy_port>` to the container.

**Step 2 (container side, `entrypoint.sh`):**
Start in-container socat: `socat TCP-LISTEN:<proxy_port>,bind=127.0.0.1,reuseaddr,fork TCP:<host_docker_internal>:<proxy_port>`

The TLS SAN on the cluster certificate typically includes `127.0.0.1`, which is why the kubeconfig server URL is rewritten to `https://127.0.0.1:<proxy_port>` (not `host.docker.internal`) — TLS verification succeeds because the container connects to `127.0.0.1` locally.

```bash
# Detect and start socat (if local cluster)
server=$(extract_kube_server "$kube_val")
if is_local_server "$server"; then
  port=$(extract_port "$server")
  proxy_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
  sed -E "s,https://(127\.0\.0\.1|localhost):[0-9]+,https://127.0.0.1:${proxy_port},g" \
    "$kube_val" > "$tmp_kube_dir/config"
  socat "TCP-LISTEN:${proxy_port},bind=${socat_bind_ip},reuseaddr,fork" "TCP:127.0.0.1:${port}" &
  kube_proxy_pid=$!
  sleep 0.2
  kill -0 "$kube_proxy_pid" 2>/dev/null \
    && docker_flags+=(-e "AIDE_KUBE_LOCAL_PORT=$proxy_port") \
    || { echo "aide: warning: kube proxy failed to start"; cp "$kube_val" "$tmp_kube_dir/config"; }
else
  cp "$kube_val" "$tmp_kube_dir/config"
fi
chmod 600 "$tmp_kube_dir/config"
docker_flags+=(-v "$tmp_kube_dir:/home/aide/.kube:ro" -e "KUBECONFIG=/home/aide/.kube/config")
```

**Pitfall:** After starting socat, wait `0.2s` and verify with `kill -0 $pid`. socat exits immediately on `EADDRNOTAVAIL` (wrong bind IP). A failed proxy start is silent without this check.

### LAN Host Proxying

For hosts that are only reachable on the LAN or via VPN (not from inside the Docker VM):

**Host side (`bin/aide`):**
1. Resolve the domain's IP: `python3 -c "import socket; print(socket.gethostbyname('$lan_domain'))"`
2. Allocate an ephemeral proxy port.
3. Start socat: `socat TCP-LISTEN:<proxy_port>,bind=<bridge_ip>,reuseaddr,fork TCP:<lan_ip>:<lan_port>`
4. Pass `AIDE_LAN_PROXIES="domain:port:proxy_port [...]"` to the container.

**Container side (`entrypoint.sh`):**
1. Parse `AIDE_LAN_PROXIES`.
2. For each entry, start in-container socat: `socat TCP-LISTEN:<lan_port>,bind=127.0.0.1,reuseaddr,fork TCP:<host_docker_internal>:<proxy_port>`
3. Inject `/etc/hosts` entry: `echo "127.0.0.1 $lan_domain" >> /etc/hosts`

The firewall must also allow outbound from the container to `host.docker.internal:<proxy_port>`. `init-firewall.sh` adds these rules when `AIDE_LAN_PROXIES` is set.

### Firewall Integration

All feature-specific firewall rules are added by `init-firewall.sh` BEFORE the ipset allowlist and RFC-1918 REJECT rules:

```
[SSH agent rule]    → ACCEPT to host.docker.internal:<ssh_port>
[K8s proxy rule]    → ACCEPT to host.docker.internal:<kube_port>
[LAN proxy rules]   → ACCEPT to host.docker.internal:<proxy_port> (per LAN host)
[ipset allowlist]   → ACCEPT matching allowed-domains
[RFC-1918 REJECT]   → REJECT private ranges
[catch-all REJECT]  → REJECT everything else
```

### Dependencies

**Depends on:** `socat` (host and container), `python3` (port allocation, IP detection), `kubectl` (kube server extraction), `iproute2` (Linux host IP detection), `getent` (container host IP resolution)

**Required by:** SSH workflows, Docker-in-Docker scenarios, Kubernetes operations, LAN service access

## Acceptance Criteria

- `ssh-add -l` inside the container lists keys from the host agent (macOS + Linux)
- `docker ps` inside the container lists host containers when `--docker` is active
- `kubectl get nodes` inside the container reaches a local cluster (Rancher Desktop, k3s)
- LAN hosts specified with `--lan-host` are resolvable and reachable inside the container
- socat is not listening on `0.0.0.0` (verify with `ss -tlnp | grep socat` on the host)
- All socat processes are killed when `aide` exits

## Open Questions / Future Work

- Remote Kubernetes clusters with private IP API servers (similar two-hop proxy but initiated differently)
- Multi-context kubeconfig support (current implementation uses the active context only)
