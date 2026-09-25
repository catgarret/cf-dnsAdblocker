#!/usr/bin/env bash
set -Eeuo pipefail

# Install a DNS relay that is reachable only through this host's Tailscale IPv4.
#
# Client -> Tailscale/WireGuard -> <tailscale-ip>:53 -> DoH -> Cloudflare Gateway
#
# Usage:
#   sudo env DOH_URL='https://xxxx.cloudflare-gateway.com/dns-query' \
#     bash install-tailscale-dns-relay.sh

trap 'rc=$?; echo; echo "[ERROR] line $LINENO: command failed (exit $rc)" >&2;       systemctl --no-pager --full status tailscale-dnsproxy.service 2>/dev/null || true;       journalctl -u tailscale-dnsproxy.service -n 30 --no-pager 2>/dev/null || true; exit $rc' ERR

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

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates tar python3 dnsutils

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# Do NOT use "curl | awk ... exit" here.  With pipefail, awk exits as soon as it
# sees tag_name and curl then gets EPIPE, producing curl(23).  Download the JSON
# completely first and parse it afterwards.
RELEASE_JSON="${TMPDIR}/release.json"
curl -fL --retry 3 --retry-all-errors   -o "${RELEASE_JSON}"   https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest

VERSION="$(python3 - "${RELEASE_JSON}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)["tag_name"])
PY
)"

if [[ -z "${VERSION}" ]]; then
  echo "Could not determine dnsproxy release." >&2
  exit 1
fi

ASSET="dnsproxy-linux-${ARCH}-${VERSION}.tar.gz"
URL="https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/${ASSET}"
ARCHIVE="${TMPDIR}/${ASSET}"

echo "Installing dnsproxy ${VERSION} for linux/${ARCH}..."
curl -fL --retry 3 --retry-all-errors -o "${ARCHIVE}" "${URL}"
tar -xzf "${ARCHIVE}" -C "${TMPDIR}"

BIN="$(find "${TMPDIR}" -type f -name dnsproxy -perm -u+x | head -n1)"
if [[ -z "${BIN}" ]]; then
  echo "dnsproxy binary not found in release archive." >&2
  exit 1
fi
install -m 0755 "${BIN}" /usr/local/bin/dnsproxy

install -d -m 0755 /etc/tailscale-dnsproxy
install -d -m 0755 /usr/local/libexec
printf '%s\n' "${DOH_URL}" > /etc/tailscale-dnsproxy/upstream-url
chmod 0600 /etc/tailscale-dnsproxy/upstream-url

cat >/usr/local/libexec/tailscale-dnsproxy-run <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail

TS_IP="$(tailscale ip -4 | head -n1)"
DOH_URL="$(cat /etc/tailscale-dnsproxy/upstream-url)"

exec /usr/local/bin/dnsproxy \
  --listen="$TS_IP" \
  --port=53 \
  --upstream="$DOH_URL" \
  --bootstrap=1.1.1.1:53 \
  --bootstrap=8.8.8.8:53 \
  --fallback=https://cloudflare-dns.com/dns-query \
  --fallback=https://dns.google/dns-query \
  --cache \
  --cache-size=4194304 \
  --cache-optimistic \
  --pending-requests-enabled \
  --timeout=10s \
  --refuse-any
RUNNER
chmod 0755 /usr/local/libexec/tailscale-dnsproxy-run

cat >/etc/systemd/system/tailscale-dnsproxy.service <<'UNIT'
[Unit]
Description=Tailscale-only DNS relay to Cloudflare Gateway DoH
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=/usr/local/libexec/tailscale-dnsproxy-run
Restart=on-failure
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

# Give systemd a moment to surface bind/TLS/config errors.
sleep 2
if ! systemctl is-active --quiet tailscale-dnsproxy.service; then
  echo "tailscale-dnsproxy failed to start." >&2
  systemctl --no-pager --full status tailscale-dnsproxy.service || true
  journalctl -u tailscale-dnsproxy.service -n 50 --no-pager || true
  exit 1
fi

echo
echo "Testing local relay through Tailscale address ${TS_IP}..."
dig @"${TS_IP}" example.com A +time=4 +tries=1 +short >/tmp/tailscale-dnsproxy-test.txt
if [[ ! -s /tmp/tailscale-dnsproxy-test.txt ]]; then
  echo "DNS test returned no A record for example.com." >&2
  journalctl -u tailscale-dnsproxy.service -n 50 --no-pager || true
  exit 1
fi

echo
echo "============================================================"
echo " Tailscale DNS relay installed successfully"
echo " dnsproxy: $(/usr/local/bin/dnsproxy --version 2>/dev/null || true)"
echo " Nameserver: ${TS_IP}"
echo " Upstream:   ${DOH_URL}"
echo "============================================================"
echo
systemctl --no-pager --full status tailscale-dnsproxy.service
echo
ss -lntup | grep -F "${TS_IP}:53" || true
echo
echo "example.com test:"
cat /tmp/tailscale-dnsproxy-test.txt
