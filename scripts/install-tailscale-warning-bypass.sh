#!/usr/bin/env bash
set -Eeuo pipefail

# Selective Korea warning.or.kr bypass over a US Tailscale subnet router.
#
# This is NOT an exit node. Only IPs resolved from the configured domain list
# are advertised as /32 (IPv4) and /128 (IPv6) routes through this US node.
# Everything else keeps using the client's normal Internet connection.
#
# By default, the script merges:
#   1) a community-maintained/listed Korea blocked-domain source
#   2) optional local overrides in /etc/tailscale-warning-bypass/domains.txt
#
# The script is intentionally conservative about route count and rejects
# private/special-use destinations.
#
# IMPORTANT: tailscale set --advertise-routes owns the node's static subnet
# route list. Do not use this installer on a node that already advertises
# unrelated custom subnet routes unless you merge those routes into the
# EXTRA_STATIC_ROUTES variable in /etc/default/tailscale-warning-bypass.

SOURCE_URL_DEFAULT="https://raw.githubusercontent.com/wpzzz/blocked-sites-in-south-korea/main/list.txt"
STATE_DIR="/var/lib/tailscale-warning-bypass"
CONF_DIR="/etc/tailscale-warning-bypass"
DEFAULTS="/etc/default/tailscale-warning-bypass"
LOCAL_LIST="${CONF_DIR}/domains.txt"
GENERATED="${STATE_DIR}/routes.txt"
MAX_ROUTES_DEFAULT=9000

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

command -v tailscale >/dev/null 2>&1 || { echo "tailscale is not installed." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl dnsutils python3

install -d -m 0755 "${STATE_DIR}" "${CONF_DIR}"
touch "${LOCAL_LIST}"
chmod 0644 "${LOCAL_LIST}"

if [[ ! -e "${DEFAULTS}" ]]; then
  cat >"${DEFAULTS}" <<'EOF'
# Optional overrides.
SOURCE_URL="https://raw.githubusercontent.com/wpzzz/blocked-sites-in-south-korea/main/list.txt"
MAX_ROUTES=9000

# Resolve blocked domains through BOTH DNS relays that clients actually use.
# This captures CDN/geolocation answers from KR and US instead of relying on
# the US host's unrelated system resolver.
RESOLVER_IPS="100.121.219.35 100.94.3.111"

# Comma-separated static routes that must ALSO stay advertised by this node.
# Example: EXTRA_STATIC_ROUTES="192.0.2.0/24,2001:db8::/48"
EXTRA_STATIC_ROUTES=""
EOF
fi

cat >/usr/local/libexec/tailscale-warning-bypass-refresh <<'REFRESH'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/tailscale-warning-bypass"
CONF_DIR="/etc/tailscale-warning-bypass"
DEFAULTS="/etc/default/tailscale-warning-bypass"
LOCAL_LIST="${CONF_DIR}/domains.txt"
SOURCE_URL_DEFAULT="https://raw.githubusercontent.com/wpzzz/blocked-sites-in-south-korea/main/list.txt"
MAX_ROUTES_DEFAULT=9000
RESOLVER_IPS_DEFAULT="100.121.219.35 100.94.3.111"

[[ -r "${DEFAULTS}" ]] && source "${DEFAULTS}"
SOURCE_URL="${SOURCE_URL:-$SOURCE_URL_DEFAULT}"
MAX_ROUTES="${MAX_ROUTES:-$MAX_ROUTES_DEFAULT}"
RESOLVER_IPS="${RESOLVER_IPS:-$RESOLVER_IPS_DEFAULT}"
EXTRA_STATIC_ROUTES="${EXTRA_STATIC_ROUTES:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60   -o "$TMP/community.txt" "$SOURCE_URL"

cat "$TMP/community.txt" "$LOCAL_LIST" 2>/dev/null   | tr -d '\r'   | sed 's/#.*$//'   | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print tolower($0)}'   | grep -E '^[a-z0-9_*-]+([.][a-z0-9_*-]+)+$'   | sed 's/^\*\.//'   | sort -u > "$TMP/domains.txt"

DOMAIN_COUNT="$(wc -l < "$TMP/domains.txt")"
echo "Resolving ${DOMAIN_COUNT} domains..."

resolve_one() {
  idx="$1"
  d="$2"
  for r in $RESOLVER_IPS; do
    dig @"$r" +time=2 +tries=1 +short A "$d" 2>/dev/null       | awk -v d="$d" -v r="$r" 'NF {print "4", $0, d, r}'
    dig @"$r" +time=2 +tries=1 +short AAAA "$d" 2>/dev/null       | awk -v d="$d" -v r="$r" 'NF {print "6", $0, d, r}'
  done

  # Progress goes to stderr so DNS results can still be redirected cleanly.
  if (( idx % 25 == 0 || idx == DOMAIN_COUNT )); then
    echo "  DNS resolution progress: ${idx}/${DOMAIN_COUNT}" >&2
  fi
}
export -f resolve_one
export RESOLVER_IPS DOMAIN_COUNT

echo "Using client-facing resolvers: $RESOLVER_IPS"
echo "This step can take a few minutes; progress will be printed every 25 domains."
nl -ba -w1 -s' ' "$TMP/domains.txt"   | xargs -r -n2 -P32 bash -c 'resolve_one "$1" "$2"' _   > "$TMP/resolved.raw" || true

python3 - "$TMP/resolved.raw" "$TMP/routes.txt" <<'PY'
import ipaddress, sys

src, dst = sys.argv[1], sys.argv[2]
routes = set()

deny = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("198.18.0.0/15"),
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("240.0.0.0/4"),
    ipaddress.ip_network("::/128"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("ff00::/8"),
    ipaddress.ip_network("2001:db8::/32"),
]

def forbidden(ip):
    if ip.is_unspecified or ip.is_loopback or ip.is_link_local or ip.is_multicast:
        return True
    return any(ip in n for n in deny if n.version == ip.version)

with open(src, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 2:
            continue
        candidate = parts[1].rstrip(".")
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError:
            # Ignore CNAMEs printed by dig +short.
            continue
        if forbidden(ip):
            continue
        routes.add(f"{ip}/32" if ip.version == 4 else f"{ip}/128")

with open(dst, "w", encoding="utf-8") as f:
    for r in sorted(routes):
        f.write(r + "\n")
PY

ROUTE_COUNT="$(wc -l < "$TMP/routes.txt")"
if (( ROUTE_COUNT == 0 )); then
  echo "No usable routes were resolved; keeping current Tailscale routes unchanged." >&2
  exit 1
fi

if (( ROUTE_COUNT > MAX_ROUTES )); then
  echo "Refusing to advertise ${ROUTE_COUNT} routes (limit ${MAX_ROUTES})." >&2
  echo "Tailscale warns that advertising more than ~10K routes can cause client issues." >&2
  exit 1
fi

ROUTES="$(paste -sd, "$TMP/routes.txt")"
if [[ -n "$EXTRA_STATIC_ROUTES" ]]; then
  ROUTES="${ROUTES},${EXTRA_STATIC_ROUTES}"
fi

tailscale set --advertise-routes="$ROUTES"
cp "$TMP/routes.txt" "$STATE_DIR/routes.txt"
cp "$TMP/domains.txt" "$STATE_DIR/domains.txt"

echo "Selective warning.or.kr bypass refreshed:"
echo "  domains: ${DOMAIN_COUNT}"
echo "  advertised routes: ${ROUTE_COUNT}"
echo "  node: $(tailscale ip -4 | head -n1)"
REFRESH
chmod 0755 /usr/local/libexec/tailscale-warning-bypass-refresh

cat >/etc/systemd/system/tailscale-warning-bypass.service <<'UNIT'
[Unit]
Description=Refresh selective Korean censorship-bypass routes over Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/tailscale-warning-bypass-refresh
UNIT

cat >/etc/systemd/system/tailscale-warning-bypass.timer <<'UNIT'
[Unit]
Description=Refresh selective Korean censorship-bypass routes hourly

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# Required for subnet routing.
cat >/etc/sysctl.d/99-tailscale-warning-bypass.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null

systemctl daemon-reload

echo
echo "Running the first route refresh in the foreground so progress is visible..."
/usr/local/libexec/tailscale-warning-bypass-refresh

echo
echo "Enabling hourly refresh timer..."
systemctl enable --now tailscale-warning-bypass.timer

echo
echo "============================================================"
echo " Selective warning.or.kr bypass installed"
echo " This is NOT an Exit Node."
echo " Only resolved blocked-destination IPs are advertised via this node."
echo "============================================================"
echo
systemctl --no-pager --full status tailscale-warning-bypass.service || true
echo
systemctl list-timers tailscale-warning-bypass.timer --no-pager
echo
echo "Local extra domains: ${LOCAL_LIST}"
echo "Generated routes:    ${GENERATED}"
