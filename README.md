# cf-dnsAdblocker

Full rebuild / troubleshooting guide: [`docs/TAILSCALE_DNS_ADBLOCK.md`](docs/TAILSCALE_DNS_ADBLOCK.md)

Selective Korea `warning.or.kr` bypass without enabling an Exit Node: [`docs/TAILSCALE_WARNING_BYPASS.md`](docs/TAILSCALE_WARNING_BYPASS.md)

Cloudflare Gateway DNS filtering + a Tailscale-only DNS relay.

## Cloudflare Gateway filter refresh

This repository runs the current `mrrfv/cloudflare-gateway-pihole-scripts` v1 workflow.

### Schedule

The filter refresh runs **daily at 03:17 UTC (12:17 KST)** and can also be started manually.

The upstream project currently ships a weekly example schedule, but there is an open upstream request to make it daily. Daily refresh is used here so frequently changing ad/tracker lists do not stay stale for a week.

### Required repository secrets

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`
- `CLOUDFLARE_LIST_ITEM_LIMIT` — optional; CGPS defaults apply when omitted.
- `PING_URL` — optional health-check URL.
- `DISCORD_WEBHOOK_URL` — optional notification webhook.

### Optional repository variables

- `ALLOWLIST_URLS` — one allowlist URL per line.
- `BLOCKLIST_URLS` — one blocklist URL per line.
- `BLOCK_PAGE_ENABLED`

If `BLOCKLIST_URLS` is empty, CGPS uses its current recommended lists. If stronger filtering is desired, set a curated list explicitly rather than stacking multiple overlapping lists and wasting the Cloudflare Gateway item quota.

## Tailscale DNS architecture

Android Private DNS (DoT) can conflict with Tailscale/MagicDNS. Instead of making Android reach the public Private DNS hostname while Tailscale is active, use a DNS resolver inside the tailnet:

```text
phone / iPad / Mac
  -> Tailscale DNS
  -> 100.x.y.z:53 on a tailnet server
  -> encrypted DoH
  -> Cloudflare Gateway
  -> CGPS ad/tracker rules
```

The client-to-server DNS packet is protected by Tailscale's WireGuard tunnel. The server-to-Cloudflare leg uses DoH.

### Install relay on a Linux Tailscale server

`scripts/install-tailscale-dns-relay.sh` installs the current AdGuardTeam `dnsproxy` release and binds it only to the host's Tailscale IPv4 address.

Example:

```bash
sudo DOH_URL='https://YOUR_LOCATION.cloudflare-gateway.com/dns-query' \
  bash scripts/install-tailscale-dns-relay.sh
```

Then, in the Tailscale admin console:

1. DNS -> Global nameservers -> Add nameserver -> Custom.
2. Enter the server's `100.x.y.z` Tailscale IPv4 address.
3. Enable **Override DNS servers**.
4. Keep MagicDNS enabled if you use tailnet hostnames.
5. Ensure the tailnet policy permits clients to reach that server on TCP/UDP 53.

On Android, set system **Private DNS** to **Automatic** (or Off) while using this design. Tailscale becomes the DNS control plane, so a separate Android Private DNS hostname is unnecessary and can conflict with the VPN DNS configuration.

### Verify on the server

```bash
sudo ss -lntup | grep ':53'
sudo journalctl -u tailscale-dnsproxy -f
```

From another tailnet device:

```bash
nslookup example.com 100.x.y.z
```

## Notes

Tailscale App Connectors are for routing traffic to applications by domain; they are not an ad-blocking DNS engine. For whole-tailnet DNS filtering, **Global nameserver + Override DNS servers** is the appropriate Tailscale mechanism.


## Dual-node DNS relay (KR + US)

For redundancy, install the same relay on both Tailscale servers:

- `kr.dongri.me`
- `us.dongri.me`

Run the same installer on each server. Each instance binds only to that server's own Tailscale IPv4 address and forwards to the same Cloudflare Gateway DoH endpoint, so the filtering policy stays identical.

After both are running, add **both Tailscale 100.x addresses** as Tailscale Global nameservers and enable **Override DNS servers**.

Tailscale/modern OS resolvers do not guarantee strict primary/secondary ordering; they may race or reorder resolvers. Because both nodes use the same Cloudflare Gateway policy, either answer is acceptable. In Korea the KR node will often be faster, while the US node provides redundancy.

Known US node:

```text
us.dongri.me -> 100.94.3.111
```

Get the KR Tailscale IPv4 after installation with:

```bash
tailscale ip -4 | head -n1
```


### KR note

KR already runs AdGuard Home on `100.121.219.35:53`. Do not install a second host-level DNS relay there.

If the host relay installer was previously attempted and failed due to port 53 already being in use, clean up only those host-level artifacts with:

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/cleanup-host-tailscale-dns-relay.sh \
  -o /tmp/cleanup-host-tailscale-dns-relay.sh && \
sudo bash /tmp/cleanup-host-tailscale-dns-relay.sh
```
