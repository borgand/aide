#!/usr/bin/env bash
set -euo pipefail

# init-firewall.sh — Default-deny iptables firewall for aide container
# Must run as root (called by entrypoint.sh before privilege drop)

export ANTHROPIC_BASE_URL="https://api.anthropic.com"

# ── Allowed domains ──────────────────────────────────────────────────────────
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
)

# Extra domains from environment (space-separated FQDNs)
if [[ -n "${AIDE_EXTRA_DOMAINS:-}" ]]; then
  read -ra EXTRA <<< "$AIDE_EXTRA_DOMAINS"
  ALLOWED_DOMAINS+=("${EXTRA[@]}")
fi

echo "aide-firewall: configuring network isolation..."

# ── Save Docker DNS NAT rules before flushing ────────────────────────────────
DNS_NAT_RULES=$(iptables-save -t nat 2>/dev/null | grep "127.0.0.11" || true)

# ── Flush all existing rules ─────────────────────────────────────────────────
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

ip6tables -F
ip6tables -X
ip6tables -t nat -F
ip6tables -t nat -X
ip6tables -t mangle -F
ip6tables -t mangle -X

# Destroy existing ipset if present
ipset destroy allowed-domains 2>/dev/null || true

# ── Restore Docker DNS NAT rules ─────────────────────────────────────────────
if [[ -n "$DNS_NAT_RULES" ]]; then
  echo "$DNS_NAT_RULES" | while IFS= read -r rule; do
    # Convert -save format back to command: strip leading -A and apply
    if [[ "$rule" =~ ^-A ]]; then
      eval "iptables -t nat $rule" 2>/dev/null || true
    fi
  done
fi

# ── Block IPv6 entirely ──────────────────────────────────────────────────────
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# ── IPv4: Allow fundamentals ─────────────────────────────────────────────────
# Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS (Docker internal resolver)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Host network (default gateway — needed for Docker bridge comms)
DEFAULT_GW=$(ip route | awk '/default/ {print $3}')
if [[ -n "$DEFAULT_GW" ]]; then
  # Allow the entire gateway subnet
  GW_SUBNET=$(ip route | awk '/default/ {print $3}' | sed 's/\.[0-9]*$/.0\/16/')
  iptables -A INPUT -s "$GW_SUBNET" -j ACCEPT
  iptables -A OUTPUT -d "$GW_SUBNET" -j ACCEPT
fi

# ── Build ipset of allowed IPs ───────────────────────────────────────────────
# Allow host.docker.internal for SSH agent proxy
if [[ -n "${SSH_AGENT_PROXY_PORT:-}" ]]; then
  HOST_IP=$(getent hosts host.docker.internal | awk '{print $1}')
  if [[ -n "$HOST_IP" ]]; then
    iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$SSH_AGENT_PROXY_PORT" -j ACCEPT
  fi
fi

# ── Local Kubernetes cluster port forwarding ─────────────────────────────────
# Allow outbound traffic to host.docker.internal on the kube proxy port.
# (The actual forwarding is done by a socat proxy started in entrypoint.sh;
# this rule only ensures the firewall permits that outbound connection.)
if [[ -n "${AIDE_KUBE_LOCAL_PORT:-}" ]]; then
  HOST_IP=$(getent hosts host.docker.internal | awk '{print $1}' 2>/dev/null || true)
  if [[ -n "$HOST_IP" ]]; then
    iptables -A OUTPUT -d "$HOST_IP" -p tcp --dport "$AIDE_KUBE_LOCAL_PORT" -j ACCEPT
    echo "aide-firewall: allowing outbound to ${HOST_IP}:${AIDE_KUBE_LOCAL_PORT} for local K8s proxy"
  fi
fi

ipset create allowed-domains hash:net

IP_REGEX='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

for domain in "${ALLOWED_DOMAINS[@]}"; do
  echo "aide-firewall: resolving $domain"
  # dig +short may return CNAMEs followed by IPs; filter to IPs only
  while IFS= read -r ip; do
    if [[ "$ip" =~ $IP_REGEX ]]; then
      ipset add allowed-domains "$ip" -exist
    fi
  done < <(dig +short A "$domain" 2>/dev/null || true)
done

# ── Set default policies to DROP ─────────────────────────────────────────────
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# ── Allow outbound to allowed domains ────────────────────────────────────────
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# REJECT (not DROP) everything else for fast failure feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable
iptables -A INPUT -j REJECT --reject-with icmp-port-unreachable

echo "aide-firewall: rules applied. Verifying..."

# ── Verify ────────────────────────────────────────────────────────────────────
# Blocked domain should fail
if curl -sf --max-time 3 https://example.com > /dev/null 2>&1; then
  echo "aide-firewall: ERROR — example.com is reachable (should be blocked)" >&2
  exit 1
fi
echo "aide-firewall: [ok] example.com blocked"

# Allowed domain should succeed
if ! curl -sf --max-time 5 https://api.anthropic.com > /dev/null 2>&1; then
  # API might return non-200 but connection should succeed; check with connect-only
  if ! curl -sf --max-time 5 --connect-timeout 5 -o /dev/null -w '' https://api.anthropic.com 2>/dev/null; then
    # Even a connection error is fine as long as it's not a firewall reject
    # Try raw TCP connect
    if ! timeout 5 bash -c 'echo > /dev/tcp/api.anthropic.com/443' 2>/dev/null; then
      echo "aide-firewall: ERROR — api.anthropic.com is not reachable (should be allowed)" >&2
      exit 1
    fi
  fi
fi
echo "aide-firewall: [ok] api.anthropic.com reachable"

echo "aide-firewall: network isolation active."
