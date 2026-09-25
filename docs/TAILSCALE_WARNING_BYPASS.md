# Selective `warning.or.kr` bypass with Tailscale

## What this solves

South Korean ISP blocking can happen above DNS, including HTTPS SNI filtering. Changing DNS alone cannot reliably prevent that because the client still connects directly through the Korean ISP.

This setup sends only destinations from a blocked-domain list through the **US Tailscale node**. It does **not** select an Exit Node and does not route ordinary Internet traffic through the US server.

```text
ordinary site
client -> normal KT/SKT/LGU+/Wi-Fi Internet

listed blocked site
client -> encrypted Tailscale tunnel -> US node -> destination
```

The Korean access ISP sees the encrypted Tailscale connection to the US node rather than the target site's HTTP Host/TLS SNI, so ISP-level DNS/HTTP/SNI blocking for those selected destinations is bypassed.

## Why not use a Tailscale App Connector for the entire block list?

App Connectors are excellent for a small set of domains, but Tailscale currently limits a tailnet to 250 configured App Connector domains. A larger censorship list can exceed that quickly.

This helper instead resolves the domains and advertises their destination IPs as normal subnet routes from the US node. Tailscale warns that very large route counts (around 10K+) can cause client issues, so the helper has a 9,000-route hard safety limit.

## Install on the US node only

Do **not** install this on the KR node. A Korean egress can still encounter the same Korean ISP filtering.

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/install-tailscale-warning-bypass.sh \
  -o /tmp/install-tailscale-warning-bypass.sh && \
sudo bash /tmp/install-tailscale-warning-bypass.sh
```

The installer:

- enables IPv4/IPv6 forwarding;
- fetches the configured blocked-domain source;
- merges local extra domains;
- resolves A/AAAA records;
- rejects private/special-use IPs;
- advertises only those /32 and /128 routes from the US Tailscale node;
- refreshes hourly with a systemd timer;
- refuses to publish more than 9,000 routes.

## Existing Exit Node / App Connector features

The US host can remain capable of being an Exit Node and an App Connector. This helper only adds selective **subnet routes**. On the phone/tablet, keep:

```text
Exit Node = None
Tailscale = connected
Use Tailscale subnets/routes = enabled
```

Traffic matching the advertised destination routes uses the US node; other traffic remains direct.

## Tailscale policy

The US connector/router tag must be allowed to advertise these routes. If the tailnet already has an auto-approver such as:

```json
{
  "autoApprovers": {
    "routes": {
      "0.0.0.0/0": ["tag:us-dongri-me"],
      "::/0": ["tag:us-dongri-me"]
    }
  }
}
```

then the more-specific /32 and /128 routes from that tagged node are automatically approved.

Otherwise approve the advertised routes in the Tailscale admin console or add an appropriate auto-approver policy.

## Domain source and local additions

Default community source:

```text
https://raw.githubusercontent.com/wpzzz/blocked-sites-in-south-korea/main/list.txt
```

This is a third-party community list, not an official KCSC feed, so it can be stale or contain false positives.

Local additions:

```text
/etc/tailscale-warning-bypass/domains.txt
```

One hostname per line:

```text
example.com
sub.example.net
```

After editing:

```bash
sudo systemctl start tailscale-warning-bypass.service
```

## Configuration

```text
/etc/default/tailscale-warning-bypass
```

Options:

```bash
SOURCE_URL="https://..."
MAX_ROUTES=9000
EXTRA_STATIC_ROUTES=""
```

`EXTRA_STATIC_ROUTES` exists because `tailscale set --advertise-routes` controls this node's static subnet-route list. If this same US node must advertise other manually configured subnets, put them there as a comma-separated list.

App Connector-learned routes and Exit Node capability are separate from this static list.

## Check status

```bash
sudo systemctl status tailscale-warning-bypass.service --no-pager
sudo systemctl list-timers tailscale-warning-bypass.timer --no-pager
wc -l /var/lib/tailscale-warning-bypass/routes.txt
head /var/lib/tailscale-warning-bypass/routes.txt
```

Manual refresh:

```bash
sudo systemctl start tailscale-warning-bypass.service
```

Logs:

```bash
sudo journalctl -u tailscale-warning-bypass.service -n 100 --no-pager
```

## Limitations

1. A domain may share a CDN IP with unrelated domains. Those unrelated destinations can temporarily follow the same US route because IP routing cannot distinguish the hostname after DNS resolution.
2. DNS answers change. The hourly refresh reduces stale routes but does not eliminate a short learning window.
3. The community list is not guaranteed complete, so a newly blocked domain may still need to be added locally.
4. A block enforced by the destination/CDN itself can behave differently from Korean ISP-level `warning.or.kr` filtering. US egress often changes the result when the restriction is based on Korean source IP, but it cannot override a destination that refuses access independently.
5. This design is intended to preserve normal direct Internet access. If truly every destination must be forced outside the Korean ISP, use an Exit Node instead.
