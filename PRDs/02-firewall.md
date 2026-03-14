# PRD-02: Firewall

## Overview

`init-firewall.sh` applies a default-deny iptables firewall inside the container before Claude Code starts. Outbound traffic is allowed only to a domain allowlist resolved at startup; IPv6 is fully blocked; RFC-1918 addresses are rejected; everything else is rejected (not dropped) for fast failure feedback. If the firewall application fails or verification fails, the container exits immediately.

## Requirements

- **FR-02-01** The firewall MUST be applied before any user process starts.
- **FR-02-02** The container MUST exit non-zero if the firewall fails to apply.
- **FR-02-03** Outbound traffic to hosts not in the allowlist MUST be rejected.
- **FR-02-04** IPv6 MUST be completely blocked (INPUT, FORWARD, OUTPUT all DROP), with loopback excepted.
- **FR-02-05** RFC-1918 addresses and link-local (`169.254.0.0/16`) MUST be rejected for DNS rebinding protection.
- **FR-02-06** Docker's internal DNS resolver (`127.0.0.11`) NAT rules MUST be preserved.
- **FR-02-07** Extra domains MUST be addable via `AIDE_EXTRA_DOMAINS` env var, `aide.yaml` `extra_domains` list, or `firewall-domains.local.txt` file.
- **FR-02-08** The firewall MUST verify itself: TEST-NET unreachable + `api.anthropic.com` reachable.
- **FR-02-09** REJECT (not DROP) MUST be used for all denied traffic.
- **FR-02-10** allowlisted domain IPs MUST be added to ipset before RFC-1918 REJECT rules (rule order matters).

## Design

### Architecture

```
init-firewall.sh execution order:
1. Read AIDE_EXTRA_DOMAINS → extend ALLOWED_DOMAINS[]
2. Save Docker DNS NAT rules (127.0.0.11) from current iptables-nat
3. Flush all iptables rules (filter, nat, mangle)
4. Flush ip6tables rules; set all IPv6 chains to DROP
5. Restore Docker DNS NAT rules
6. Add IPv4 fundamentals: loopback, DNS (UDP/53), ESTABLISHED/RELATED, default gateway
7. Add feature-specific allow rules: SSH agent, K8s proxy, LAN proxy ports (to host.docker.internal)
8. Resolve all allowed domains with dig → add IPs to ipset hash:net 'allowed-domains'
9. Set default policies to DROP
10. Allow outbound to ipset 'allowed-domains'
11. REJECT RFC-1918 and link-local ranges
12. REJECT all other output; REJECT all other input
13. Verify: TEST-NET blocked + api.anthropic.com reachable
```

### Default Allowed Domains

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API |
| `registry.npmjs.org` | npm package registry |
| `pypi.org` | Python package index |
| `files.pythonhosted.org` | Python package downloads |
| `proxy.golang.org` | Go module proxy |
| `sum.golang.org` | Go module checksum database |
| `github.com` | Source code hosting |
| `gitlab.com` | Source code hosting |
| `objects.githubusercontent.com` | GitHub raw content |
| `playwright.azureedge.net` | Playwright browser downloads |

### iptables Rule Chain (IPv4)

```
INPUT chain:
  -A INPUT -i lo         -j ACCEPT
  -A INPUT -p udp --sport 53  -j ACCEPT   (DNS responses)
  -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED  -j ACCEPT
  -A INPUT -s <default_gw>/32  -j ACCEPT   (Docker bridge gateway)
  -A INPUT  -j REJECT --reject-with icmp-port-unreachable

OUTPUT chain:
  -A OUTPUT -o lo        -j ACCEPT
  -A OUTPUT -p udp --dport 53  -j ACCEPT  (DNS queries)
  -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED  -j ACCEPT
  -A OUTPUT -d <default_gw>/32  -j ACCEPT
  [SSH agent rule if SSH_AGENT_PROXY_PORT set]
  [K8s proxy rule if AIDE_KUBE_LOCAL_PORT set]
  [LAN proxy rules if AIDE_LAN_PROXIES set]
  -A OUTPUT -m set --match-set allowed-domains dst  -j ACCEPT
  -A OUTPUT -d 10.0.0.0/8       -j REJECT --reject-with icmp-net-unreachable
  -A OUTPUT -d 172.16.0.0/12    -j REJECT --reject-with icmp-net-unreachable
  -A OUTPUT -d 192.168.0.0/16   -j REJECT --reject-with icmp-net-unreachable
  -A OUTPUT -d 169.254.0.0/16   -j REJECT --reject-with icmp-net-unreachable
  -A OUTPUT  -j REJECT --reject-with icmp-net-unreachable

Default policies: INPUT DROP, FORWARD DROP, OUTPUT DROP
```

### IPv6

```
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT  -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
```

### ipset Usage

```bash
ipset create allowed-domains hash:net
# For each allowed domain:
dig +short A "$domain" | while read ip; do
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ipset add allowed-domains "$ip" -exist
done
```

`hash:net` allows CIDR prefixes if needed. `-exist` suppresses errors for duplicate entries.

### DNS NAT Preservation

Docker injects NAT rules to redirect container DNS to its internal resolver at `127.0.0.11`. These rules are in the `nat` table and must survive the flush:

```bash
DNS_NAT_RULES=$(iptables-save -t nat 2>/dev/null | grep "127.0.0.11" || true)
# ... flush all rules ...
if [[ -n "$DNS_NAT_RULES" ]]; then
  printf '*nat\n%s\nCOMMIT\n' "$DNS_NAT_RULES" | iptables-restore --noflush
fi
```

### Extra Domains

Three mechanisms to add domains beyond the default list:

1. **Environment variable** (passed by `bin/aide`):
   ```bash
   AIDE_EXTRA_DOMAINS="registry.example.com cdn.example.com"
   ```

2. **`aide.yaml`** (project-level, committed):
   ```yaml
   extra_domains:
     - registry.example.com
   ```
   `bin/aide` merges this into `AIDE_EXTRA_DOMAINS` before `docker run`.

3. **`firewall-domains.local.txt`** (per-engineer, gitignored):
   One domain per line, comments with `#`. `bin/aide` reads this and appends to `AIDE_EXTRA_DOMAINS`.

All three sources are merged by `bin/aide` into a single space-separated `AIDE_EXTRA_DOMAINS` env var passed to the container.

### Feature-Specific Firewall Rules

When proxy features are active, additional OUTPUT rules are added before the ipset block:

**SSH agent proxy** (when `SSH_AGENT_PROXY_PORT` is set):
```bash
HOST_IP=$(getent hosts host.docker.internal | awk '{print $1}')
iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$SSH_AGENT_PROXY_PORT" -j ACCEPT
```

**Local K8s proxy** (when `AIDE_KUBE_LOCAL_PORT` is set):
```bash
iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$AIDE_KUBE_LOCAL_PORT" -j ACCEPT
```

**LAN host proxies** (when `AIDE_LAN_PROXIES` is set):
For each `domain:port:proxy_port` in `AIDE_LAN_PROXIES`:
```bash
iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$proxy_port" -j ACCEPT
```

These rules are added to `host.docker.internal`'s IP (the Docker bridge gateway visible to the container), not to `0.0.0.0`.

### Verification

```bash
# TEST-NET (192.0.2.0/24) — RFC 5737 reserved, never routable, never in allowlist
if curl -sf --max-time 3 http://192.0.2.1 >/dev/null 2>&1; then
  echo "ERROR: firewall not blocking" >&2; exit 1
fi

# Allowed domain must be reachable
if ! timeout 5 bash -c 'echo > /dev/tcp/api.anthropic.com/443' 2>/dev/null; then
  echo "ERROR: api.anthropic.com not reachable" >&2; exit 1
fi
```

### Implementation Hints

**Pitfall 1 — nf_tables DNAT on loopback**
Debian bookworm uses the nf_tables backend for iptables. DNAT rules for loopback-destined traffic (`-d 127.0.0.1`) do not work reliably with nf_tables. Do NOT use DNAT to redirect container traffic to in-container socat proxies for K8s or LAN. Instead, configure socat to listen on `127.0.0.1:<port>` directly in `entrypoint.sh`.

**Pitfall 2 — DNS NAT rules**
Always save and restore `127.0.0.11` NAT rules. If they are lost, `apt`, `pip`, `npm`, and all other tools inside the container will fail DNS resolution.

**Pitfall 3 — ipset must exist before iptables references it**
`ipset create allowed-domains hash:net` must run before any `iptables -m set --match-set allowed-domains` rule. If the ipset does not exist, the `iptables` call fails and the script exits.

**Pitfall 4 — Rule order: allowlist before RFC-1918 REJECT**
Allowed domains that resolve to private IPs (e.g., an internal registry at `10.x.x.x`) will be blocked if the RFC-1918 REJECT rule appears before the ipset ACCEPT rule. Always add `ACCEPT` for the ipset before the `REJECT` rules.

**Pitfall 5 — Destroy ipset before recreating**
If the container is restarted or the script is run twice, `ipset create` will fail because the set already exists. Always run `ipset destroy allowed-domains 2>/dev/null || true` before creating it.

### Dependencies

**Depends on:** `iptables`, `ip6tables`, `ipset`, `iproute2`, `dnsutils` (for `dig`) — all installed by the Dockerfile. `NET_ADMIN` and `NET_RAW` capabilities must be granted by `docker run`.

**Required by:** `entrypoint.sh` (calls this script as its first action)

## Acceptance Criteria

- Container starts cleanly and firewall verification passes
- `curl http://192.0.2.1` from inside the container returns immediately with a connection refused / unreachable error (no timeout)
- `curl https://api.anthropic.com` from inside the container succeeds
- `curl https://example.com` from inside the container fails
- Adding a domain to `AIDE_EXTRA_DOMAINS` makes it reachable after restart
- A domain that fails to resolve (typo, DNS unavailable) produces a stderr WARNING but does NOT abort the container; traffic to that domain will be blocked
- Container fails to start if `init-firewall.sh` exits non-zero (tested by removing network capability)

## Open Questions / Future Work

- IP address rotation: if a domain's IPs change after container start, traffic will be blocked until restart. Periodic re-resolution is not implemented.
- Rate limiting: no per-IP rate limits are applied (not currently needed)
