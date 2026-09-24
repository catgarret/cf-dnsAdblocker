# cf-dnsAdblocker

Uses GitHub Actions to automatically refresh Cloudflare Gateway ad-blocking lists with [mrrfv/cloudflare-gateway-pihole-scripts](https://github.com/mrrfv/cloudflare-gateway-pihole-scripts).

## Schedule

The workflow runs every Monday at 03:07 UTC and can also be started manually from GitHub Actions.

A keepalive job is included because GitHub may automatically disable scheduled workflows in inactive public repositories.

## Required repository secrets

- `CLOUDFLARE_API_TOKEN` — Cloudflare API token with the Zero Trust permissions required by CGPS.
- `CLOUDFLARE_ACCOUNT_ID` — Cloudflare account ID.
- `CLOUDFLARE_LIST_ITEM_LIMIT` — optional list-item limit; CGPS defaults apply when omitted.
- `PING_URL` — optional health-check URL called after a successful refresh.
- `DISCORD_WEBHOOK_URL` — optional CGPS notification webhook.

## Optional repository variables

- `ALLOWLIST_URLS` — one allowlist URL per line.
- `BLOCKLIST_URLS` — one blocklist URL per line.
- `BLOCK_PAGE_ENABLED` — enables the CGPS block page when supported by the Cloudflare account.

The workflow checks out the current upstream `v1` branch and uses the current Node.js LTS runtime instead of pinning an obsolete Node version.
