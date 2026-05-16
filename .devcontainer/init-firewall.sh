#!/usr/bin/env bash
# init-firewall.sh — deny-by-default outbound firewall for the openab sandbox.
#
# Strategy (fail-closed): set the OUTPUT policy to DROP *first*, so any error
# partway through this script leaves the container with no network rather than
# open network. Only then are loopback, DNS, established connections, and the
# resolved IPs of the allowlisted domains permitted.
#
# Inbound traffic is intentionally left untouched: the threat model is data
# exfiltration / an agent phoning home, which is an outbound concern.
set -euo pipefail

ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/workspaces/claude-sandbox/.devcontainer/allowed-domains.txt}"
IPSET_NAME="allowed-domains"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "init-firewall: must run as root (use sudo)" >&2
  exit 1
fi

if [[ ! -f "$ALLOWED_DOMAINS_FILE" ]]; then
  echo "init-firewall: allowlist not found at $ALLOWED_DOMAINS_FILE" >&2
  exit 1
fi

# --- Fail closed: deny all outbound immediately ---------------------------
iptables -P OUTPUT DROP
iptables -F OUTPUT

# Block all IPv6 outbound (we only build an IPv4 allowlist below); without
# this an IPv6-capable container could bypass the filter entirely.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -P OUTPUT DROP 2>/dev/null || true
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
fi

# --- Baseline allows ------------------------------------------------------
# Loopback (includes Docker's embedded DNS resolver at 127.0.0.11).
iptables -A OUTPUT -o lo -j ACCEPT
# Return traffic for connections this container established.
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# DNS — must be allowed before we can resolve the allowlist itself.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# --- Build the allowed-IP set from the domain list ------------------------
ipset destroy "$IPSET_NAME" 2>/dev/null || true
ipset create "$IPSET_NAME" hash:ip

resolved_ips=0
while read -r line || [[ -n "$line" ]]; do
  domain="${line%%#*}"                          # strip inline comments
  domain="$(echo -n "$domain" | tr -d '[:space:]')"
  [[ -z "$domain" ]] && continue

  ips="$(dig +short A "$domain" | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)"
  if [[ -z "$ips" ]]; then
    echo "init-firewall: warning: could not resolve '$domain' — skipping" >&2
    continue
  fi
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
    resolved_ips=$((resolved_ips + 1))
  done <<< "$ips"
done < "$ALLOWED_DOMAINS_FILE"

# Fail closed: an empty allowlist almost certainly means something is wrong.
if [[ "$resolved_ips" -eq 0 ]]; then
  echo "init-firewall: no domains resolved — refusing to leave network open" >&2
  exit 1
fi

# Permit outbound traffic to any IP in the allowlist set.
iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

echo "init-firewall: active — $resolved_ips allowed IP(s) from $ALLOWED_DOMAINS_FILE"
