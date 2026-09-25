#!/usr/bin/env bash
set -euo pipefail

# Installs AdGuardTeam/dnsproxy as a DNS relay reachable only over Tailscale.
# Usage:
#   sudo DOH_URL='https://example.cloudflare-gateway.com/dns-query' bash install-tailscale-dns-relay.sh
#
# Client -> Tailscale/WireGuard -> this host:53 -> DoH -> Cloudflare Gateway

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

: "${DOH_URL:?Set DOH_URL to your Cloudflare Gateway DoH endpoint}"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale is not installed." >&2
  exit 1
fi

TS_IP="$(tailscale ip -4 | head -n1)"
if [[ -z "${TS_IP}" ]]; then
  echo "No Tailscale IPv4 address found." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

apt-get update
apt-get install -y curl ca-certificates tar

VERSION="$(curl -fsSL https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest   | awk -F'"' '/"tag_name":/ {print $4; exit}')"
if [[ -z "${VERSION}" ]]; then
  echo "Could not determine dnsproxy release." >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

ARCHIVE="${TMPDIR}/dnsproxy.tar.gz"
URL="https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-${ARCH}-${VERSION}.tar.gz"

echo "Installing dnsproxy ${VERSION} for ${ARCH}..."
curl -fL --retry 3 -o "${ARCHIVE}" "${URL}"
tar -xzf "${ARCHIVE}" -C "${TMPDIR}"
BIN="$(find "${TMPDIR}" -type f -name dnsproxy -perm -u+x | head -n1)"
if [[ -z "${BIN}" ]]; then
  echo "dnsproxy binary not found in release archive." >&2
  exit 1
fi
install -m 0755 "${BIN}" /usr/local/bin/dnsproxy

install -d -m 0755 /etc/tailscale-dnsproxy
printf '%s\n' "${DOH_URL}" > /etc/tailscale-dnsproxy/upstream-url
chmod 0600 /etc/tailscale-dnsproxy/upstream-url

cat >/usr/local/libexec/tailscale-dnsproxy-run <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
TS_IP="$(tailscale ip -4 | head -n1)"
DOH_URL="$(cat /etc/tailscale-dnsproxy/upstream-url)"
exec /usr/local/bin/dnsproxy   -l "$TS_IP"   -p 53   -u "$DOH_URL"   -b 1.1.1.1:53   -b 8.8.8.8:53   --cache   --refuse-any
RUNNER
chmod 0755 /usr/local/libexec/tailscale-dnsproxy-run

cat >/etc/systemd/system/tailscale-dnsproxy.service <<'UNIT'
[Unit]
Description=Tailscale-only DNS relay to encrypted DoH upstream
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=/usr/local/libexec/tailscale-dnsproxy-run
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now tailscale-dnsproxy.service

echo
echo "Tailscale DNS relay installed."
echo "Nameserver to add in Tailscale Admin DNS: ${TS_IP}"
echo
systemctl --no-pager --full status tailscale-dnsproxy.service
echo
ss -lntup | grep -E "(${TS_IP//./\\.}):53\b" || true
