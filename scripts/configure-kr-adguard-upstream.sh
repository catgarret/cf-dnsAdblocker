#!/usr/bin/env bash
set -Eeuo pipefail

# Configure the existing KR AdGuard Home as the Tailscale DNS resolver.
#
# Normal path:
#   client -> KR AdGuard Home -> Cloudflare Gateway DoH
#
# Availability-first fallback:
#   Gateway transport failure -> Cloudflare public DoH / Google public DoH
#
# This intentionally does NOT modify the existing dns-forwarder container.
# That container can continue serving dns.dongri.me independently.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

GATEWAY_DOH="${GATEWAY_DOH:-https://yrx058qv17.cloudflare-gateway.com/dns-query}"
CF_FALLBACK="${CF_FALLBACK:-https://cloudflare-dns.com/dns-query}"
GOOGLE_FALLBACK="${GOOGLE_FALLBACK:-https://dns.google/dns-query}"

for c in docker python3 dig tailscale; do
  command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }
done

docker inspect adguardhome >/dev/null 2>&1 || {
  echo "Container 'adguardhome' not found." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

docker cp adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml "$TMP/AdGuardHome.yaml"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$TMP/AdGuardHome.yaml" "$TMP/AdGuardHome.yaml.bak-${STAMP}"

python3 - "$TMP/AdGuardHome.yaml" "$GATEWAY_DOH" "$CF_FALLBACK" "$GOOGLE_FALLBACK" <<'PY'
import sys

path, gateway, cf, google = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

def replace_list_block(lines, key, values):
    out = []
    i = 0
    replaced = False
    prefix = "  " + key + ":"
    while i < len(lines):
        line = lines[i]
        if line.startswith(prefix):
            out.append(prefix + "\n")
            for v in values:
                out.append(f"    - {v}\n")
            i += 1
            while i < len(lines):
                # stop at next peer key under dns:
                if lines[i].startswith("  ") and not lines[i].startswith("    "):
                    break
                i += 1
            replaced = True
            continue
        out.append(line)
        i += 1
    if not replaced:
        raise SystemExit(f"{key} block not found; refusing to write")
    return out

lines = replace_list_block(lines, "upstream_dns", [gateway])
lines = replace_list_block(lines, "fallback_dns", [cf, google])

# With a single primary upstream, "parallel" adds no benefit.  Keep behavior
# deterministic and let fallback_dns handle transport failure.
for i, line in enumerate(lines):
    if line.startswith("  upstream_mode:"):
        lines[i] = "  upstream_mode: load_balance\n"

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

docker cp "$TMP/AdGuardHome.yaml.bak-${STAMP}"   "adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml.bak-${STAMP}"
docker cp "$TMP/AdGuardHome.yaml"   adguardhome:/opt/adguardhome/conf/AdGuardHome.yaml

echo "Restarting AdGuard Home..."
docker restart adguardhome >/dev/null

TS_IP="$(tailscale ip -4 | head -n1)"
for _ in $(seq 1 15); do
  if dig @"${TS_IP}" example.com A +time=2 +tries=1 +short       | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    break
  fi
  sleep 1
done

echo
echo "Current AdGuard Home DNS upstream configuration:"
docker exec adguardhome sh -c '
awk "
  /^dns:/ {indns=1}
  indns && /^  upstream_dns:/ {show=1}
  show {print}
  show && /^  bootstrap_dns:/ {exit}
" /opt/adguardhome/conf/AdGuardHome.yaml
'

echo
echo "Normal DNS test via KR Tailscale address (${TS_IP}):"
dig @"${TS_IP}" example.com A +time=3 +tries=1 +short

echo
echo "Known blocked-domain test:"
dig @"${TS_IP}" app-measurement.com A +time=3 +tries=1

echo
echo "Backup saved inside container:"
echo "/opt/adguardhome/conf/AdGuardHome.yaml.bak-${STAMP}"
