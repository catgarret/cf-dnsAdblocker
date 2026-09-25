#!/usr/bin/env bash
set -Eeuo pipefail

# Repoint the existing KR AdGuard Home container to the existing
# dns-forwarder container, which already forwards to the Cloudflare Gateway.
#
# Safe behavior:
# - auto-detect dns-forwarder container IP
# - verify it answers DNS before making changes
# - create timestamped backup of AdGuardHome.yaml
# - replace only the upstream_dns block
# - restart AdGuard Home
# - verify normal DNS + known blocked-domain behavior
#
# It does NOT alter Docker networks or remove any containers.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

for c in docker python3 dig; do
  command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }
done

docker inspect adguardhome >/dev/null 2>&1 || { echo "Container 'adguardhome' not found." >&2; exit 1; }
docker inspect dns-forwarder >/dev/null 2>&1 || { echo "Container 'dns-forwarder' not found." >&2; exit 1; }

FWD_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dns-forwarder)"
if [[ -z "${FWD_IP}" ]]; then
  echo "Could not determine dns-forwarder IP." >&2
  exit 1
fi

echo "dns-forwarder IP: ${FWD_IP}"
echo "Testing dns-forwarder before changing AdGuard Home..."
if ! dig @"${FWD_IP}" example.com A +time=3 +tries=1 +short | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
  echo "dns-forwarder did not answer a normal DNS query; refusing to modify AdGuard Home." >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

docker cp adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml "$TMP/AdGuardHome.yaml"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$TMP/AdGuardHome.yaml" "$TMP/AdGuardHome.yaml.bak-${STAMP}"

python3 - "$TMP/AdGuardHome.yaml" "${FWD_IP}" <<'PY'
import sys

path, ip = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
i = 0
replaced = False
while i < len(lines):
    line = lines[i]
    if line.startswith("  upstream_dns:"):
        out.append("  upstream_dns:\n")
        out.append(f"    - {ip}\n")
        i += 1
        while i < len(lines):
            if lines[i].startswith("  upstream_dns_file:"):
                break
            i += 1
        replaced = True
        continue
    out.append(line)
    i += 1

if not replaced:
    raise SystemExit("upstream_dns block not found; refusing to write")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY

# Keep a persistent backup inside the container.
docker cp "$TMP/AdGuardHome.yaml.bak-${STAMP}"   "adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml.bak-${STAMP}"
docker cp "$TMP/AdGuardHome.yaml"   adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml

echo "Restarting AdGuard Home..."
docker restart adguardhome >/dev/null
sleep 3

TS_IP="$(tailscale ip -4 | head -n1)"
echo
echo "Verifying KR Tailscale DNS at ${TS_IP}:53..."
dig @"${TS_IP}" example.com A +time=3 +tries=1 +short

echo
echo "Known blocked-domain test (expected: 0.0.0.0 / NXDOMAIN / empty blocked answer):"
dig @"${TS_IP}" app-measurement.com A +time=3 +tries=1

echo
echo "Current AdGuard Home upstream block:"
docker exec adguardhome sh -c '
awk "
  /^dns:/ {show=1}
  show && /^  upstream_dns:/ {inup=1}
  inup {print}
  inup && /^  upstream_dns_file:/ {exit}
" /opt/adguardhome/conf/AdGuardHome.yaml
'

echo
echo "Backup saved inside container:"
echo "/opt/adguardhome/conf/AdGuardHome.yaml.bak-${STAMP}"
