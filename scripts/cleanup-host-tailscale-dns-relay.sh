#!/usr/bin/env bash
set -Eeuo pipefail

# Remove only the host-level tailscale-dnsproxy artifacts created by
# install-tailscale-dns-relay.sh.
#
# This intentionally DOES NOT touch Docker, AdGuard Home, dns-forwarder,
# cloudflared, Nginx Proxy Manager, or any container/network configuration.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

echo "Stopping failed host-level tailscale-dnsproxy service..."
systemctl disable --now tailscale-dnsproxy.service 2>/dev/null || true
systemctl reset-failed tailscale-dnsproxy.service 2>/dev/null || true

echo "Removing host-level service and runner..."
rm -f /etc/systemd/system/tailscale-dnsproxy.service
rm -f /usr/local/libexec/tailscale-dnsproxy-run
rm -rf /etc/tailscale-dnsproxy

# The installer placed a standalone dnsproxy binary at /usr/local/bin/dnsproxy.
# Remove it only if no active systemd unit references it.
if ! grep -Rqs '/usr/local/bin/dnsproxy' /etc/systemd/system /lib/systemd/system 2>/dev/null; then
  rm -f /usr/local/bin/dnsproxy
fi

systemctl daemon-reload

echo
echo "Cleanup complete."
echo "Existing Docker DNS stack was not touched."
echo
echo "Current port 53 listeners:"
ss -H -lntup 2>/dev/null | grep -E '(:53[[:space:]]|:53$)' || true

echo
echo "Current Docker DNS containers:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null   | grep -E '(^NAMES|adguard|dnsproxy|dns-forwarder)' || true
