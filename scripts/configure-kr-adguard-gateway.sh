#!/usr/bin/env bash
set -Eeuo pipefail

# Reconfigure the existing KR AdGuard Home resolver so its normal upstream is
# the Cloudflare Gateway DoH location, while keeping encrypted public DNS as
# fail-open fallback.
#
# This script:
# - does NOT remove the existing Docker DNS stack;
# - does NOT touch the dns-forwarder/cloudflared containers;
# - backs up AdGuardHome.yaml before changing it;
# - stops AdGuard Home before editing so the running process cannot overwrite it;
# - restores the backup automatically if the container fails to come back.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

: "${DOH_URL:?Set DOH_URL to the Cloudflare Gateway DoH endpoint}"

command -v docker >/dev/null 2>&1 || { echo "docker is not installed." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is not installed." >&2; exit 1; }
command -v dig >/dev/null 2>&1 || {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y dnsutils
}

if ! docker inspect adguardhome >/dev/null 2>&1; then
  echo "Docker container 'adguardhome' was not found." >&2
  exit 1
fi

CONF_DIR="$(docker inspect adguardhome --format '{{range .Mounts}}{{if eq .Destination "/opt/adguardhome/conf"}}{{.Source}}{{end}}{{end}}')"
if [[ -z "${CONF_DIR}" ]]; then
  echo "Could not find the host mount for /opt/adguardhome/conf." >&2
  echo "Run: docker inspect adguardhome --format '{{json .Mounts}}'" >&2
  exit 1
fi

CFG="${CONF_DIR}/AdGuardHome.yaml"
if [[ ! -f "${CFG}" ]]; then
  echo "AdGuardHome.yaml not found at ${CFG}" >&2
  exit 1
fi

TS_IP="$(tailscale ip -4 | head -n1)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="${CFG}.pre-cloudflare-gateway-${STAMP}.bak"

echo "Config:  ${CFG}"
echo "Backup:  ${BACKUP}"
echo "TS DNS:  ${TS_IP}:53"

docker stop adguardhome >/dev/null
cp -a "${CFG}" "${BACKUP}"

export AGH_CFG="${CFG}"
export AGH_DOH_URL="${DOH_URL}"

if ! python3 <<'PY'
import os
from pathlib import Path

path = Path(os.environ["AGH_CFG"])
doh = os.environ["AGH_DOH_URL"].strip()

lines = path.read_text(encoding="utf-8").splitlines()

def replace_key_block(lines, key, replacement):
    target = f"  {key}:"
    for i, line in enumerate(lines):
        if line == target or line.startswith(target + " "):
            j = i + 1
            # List/child lines for dns-level keys are indented 4+ spaces.
            while j < len(lines):
                nxt = lines[j]
                if nxt and not nxt.startswith("    "):
                    break
                j += 1
            return lines[:i] + replacement + lines[j:]
    raise RuntimeError(f"Could not find dns.{key}")

def replace_scalar(lines, key, value):
    prefix = f"  {key}:"
    for i, line in enumerate(lines):
        if line.startswith(prefix):
            lines[i] = f"  {key}: {value}"
            return lines
    raise RuntimeError(f"Could not find dns.{key}")

lines = replace_key_block(lines, "upstream_dns", [
    "  upstream_dns:",
    f"    - {doh}",
])
lines = replace_key_block(lines, "fallback_dns", [
    "  fallback_dns:",
    "    - https://cloudflare-dns.com/dns-query",
    "    - https://dns.google/dns-query",
])
lines = replace_scalar(lines, "upstream_mode", "load_balance")
lines = replace_scalar(lines, "cache_optimistic", "true")

path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
then
  echo "Config edit failed; restoring backup." >&2
  cp -a "${BACKUP}" "${CFG}"
  docker start adguardhome >/dev/null || true
  exit 1
fi

docker start adguardhome >/dev/null

ok=0
for _ in {1..20}; do
  if docker ps --format '{{.Names}}' | grep -qx adguardhome; then
    if dig @"${TS_IP}" example.com A +time=2 +tries=1 +short | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
      ok=1
      break
    fi
  fi
  sleep 1
done

if [[ "${ok}" -ne 1 ]]; then
  echo "AdGuard Home did not recover cleanly; restoring backup." >&2
  docker stop adguardhome >/dev/null 2>&1 || true
  cp -a "${BACKUP}" "${CFG}"
  docker start adguardhome >/dev/null || true
  exit 1
fi

echo
echo "============================================================"
echo " KR AdGuard Home now uses Cloudflare Gateway as primary"
echo " Tailscale DNS: ${TS_IP}"
echo " Fail-open: Cloudflare public DoH + Google DoH"
echo " Backup: ${BACKUP}"
echo "============================================================"
echo
echo "Normal DNS test:"
dig @"${TS_IP}" example.com A +time=3 +tries=1
echo
echo "Known tracker/ad-domain test (inspect returned status/answer):"
dig @"${TS_IP}" app-measurement.com A +time=3 +tries=1 || true
