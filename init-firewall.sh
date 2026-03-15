#!/usr/bin/env bash
# init-firewall.sh — Default-deny iptables firewall for aide container.
# Must run as root before any user process starts.
# Exits non-zero on any failure (fail-closed).
set -euo pipefail

# ---------- Default allowed domains ----------
ALLOWED_DOMAINS=(
  api.anthropic.com
  registry.npmjs.org
  pypi.org
  files.pythonhosted.org
  proxy.golang.org
  sum.golang.org
  github.com
  gitlab.com
  objects.githubusercontent.com
  playwright.azureedge.net
  claude.ai
  auth.anthropic.com
  statsig.anthropic.com
)

# ---------- Step 1: Merge extra domains ----------
if [[ -n "${AIDE_EXTRA_DOMAINS:-}" ]]; then
  read -ra _extra <<< "$AIDE_EXTRA_DOMAINS"
  ALLOWED_DOMAINS+=("${_extra[@]}")
fi

# ---------- Step 2: Save Docker DNS NAT rules (127.0.0.11) ----------
DNS_NAT_RULES=$(iptables-save -t nat 2>/dev/null | grep "127.0.0.11" || true)

# ---------- Step 3: Flush all iptables rules ----------
iptables -F
iptables -X 2>/dev/null || true
iptables -t nat -F
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F
iptables -t mangle -X 2>/dev/null || true

# ---------- Step 4: Block IPv6 completely ----------
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

# ---------- Step 5: Restore Docker DNS NAT rules ----------
if [[ -n "$DNS_NAT_RULES" ]]; then
  printf '*nat\n%s\nCOMMIT\n' "$DNS_NAT_RULES" | iptables-restore --noflush
fi

# ---------- Step 6: IPv4 fundamentals ----------
# Loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS (UDP 53)
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# Established/related connections
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Default gateway (Docker bridge) — parsed from /proc/net/route (no iproute2 needed)
DEFAULT_GW=""
while read -r _iface dest gw _rest; do
  if [[ "$dest" == "00000000" ]]; then
    printf -v DEFAULT_GW '%d.%d.%d.%d' \
      "0x${gw:6:2}" "0x${gw:4:2}" "0x${gw:2:2}" "0x${gw:0:2}"
    break
  fi
done < <(tail -n +2 /proc/net/route)
if [[ -n "$DEFAULT_GW" ]]; then
  iptables -A INPUT  -s "$DEFAULT_GW"/32 -j ACCEPT
  iptables -A OUTPUT -d "$DEFAULT_GW"/32 -j ACCEPT
fi

# ---------- Step 7: Feature-specific allow rules ----------
HOST_IP=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' || true)

# SSH agent proxy
if [[ -n "${SSH_AGENT_PROXY_PORT:-}" && -n "$HOST_IP" ]]; then
  iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$SSH_AGENT_PROXY_PORT" -j ACCEPT
fi

# K8s proxy
if [[ -n "${AIDE_KUBE_LOCAL_PORT:-}" && -n "$HOST_IP" ]]; then
  iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$AIDE_KUBE_LOCAL_PORT" -j ACCEPT
fi

# LAN proxies
if [[ -n "${AIDE_LAN_PROXIES:-}" && -n "$HOST_IP" ]]; then
  for spec in $AIDE_LAN_PROXIES; do
    IFS=: read -r _domain _port proxy_port <<< "$spec"
    iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$proxy_port" -j ACCEPT
  done
fi

# ---------- Step 8: Resolve allowed domains → ipset ----------
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(dig +short A "$domain" 2>/dev/null || true)
  if [[ -z "$ips" ]]; then
    echo "WARNING: could not resolve $domain — traffic will be blocked" >&2
    continue
  fi
  while IFS= read -r ip; do
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ipset add allowed-domains "$ip" -exist
    fi
  done <<< "$ips"
done

# ---------- Step 9: Set default policies to DROP ----------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# ---------- Step 10: Allow outbound to ipset ----------
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# ---------- Step 11: REJECT RFC-1918 and link-local ----------
iptables -A OUTPUT -d 10.0.0.0/8       -j REJECT --reject-with icmp-net-unreachable
iptables -A OUTPUT -d 172.16.0.0/12    -j REJECT --reject-with icmp-net-unreachable
iptables -A OUTPUT -d 192.168.0.0/16   -j REJECT --reject-with icmp-net-unreachable
iptables -A OUTPUT -d 169.254.0.0/16   -j REJECT --reject-with icmp-net-unreachable

# ---------- Step 12: Catch-all REJECT ----------
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable
iptables -A INPUT  -j REJECT --reject-with icmp-port-unreachable

# ---------- Step 13: Verification ----------
# TEST-NET (RFC 5737) must be unreachable
if curl -sf --max-time 3 http://192.0.2.1 >/dev/null 2>&1; then
  echo "ERROR: firewall verification failed — TEST-NET is reachable" >&2
  exit 1
fi

# api.anthropic.com must be reachable
if ! timeout 5 bash -c 'echo > /dev/tcp/api.anthropic.com/443' 2>/dev/null; then
  echo "ERROR: firewall verification failed — api.anthropic.com not reachable" >&2
  exit 1
fi

echo "aide: firewall applied and verified"
