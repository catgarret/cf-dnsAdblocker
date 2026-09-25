# Tailscale DNS ad-blocking setup

This document records the full setup so it can be rebuilt later without relying on chat history.

## Goal

Use Tailscale as the DNS control plane on phones, tablets, and computers, while Cloudflare Gateway provides the filtering policy.

```text
client
  -> Tailscale DNS
  -> KR or US tailnet DNS relay:53
  -> encrypted DoH
  -> Cloudflare Gateway
  -> automated ad/tracker blocklists
```

Two relays are used for redundancy:

- KR Tailscale server
- US Tailscale server

Both use the same Cloudflare Gateway DoH location, so either resolver applies the same filtering policy.

## Why this architecture

Android Private DNS (DoT) and a VPN/tailnet can interact poorly on some networks.  With this design, Android does not need to reach a public DoT hostname while Tailscale is active.

Client-to-relay DNS traffic travels inside the encrypted Tailscale/WireGuard tunnel.  Relay-to-Cloudflare traffic is DNS-over-HTTPS.

## 1. Install the relay on BOTH Linux Tailscale servers

Do not commit the real Cloudflare Gateway DoH URL to this public repository.  Supply it only as an environment variable when installing.

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/install-tailscale-dns-relay.sh \
  -o /tmp/install-tailscale-dns-relay.sh && \
sudo env DOH_URL='https://YOUR-ID.cloudflare-gateway.com/dns-query' \
  bash /tmp/install-tailscale-dns-relay.sh
```

Run the command once on the KR server and once on the US server.

The installer:

- detects the server's own Tailscale IPv4;
- downloads the latest AdGuardTeam `dnsproxy` release;
- binds DNS only to `<tailscale-ip>:53`;
- forwards upstream queries using encrypted DoH;
- enables a 4 MiB in-memory cache;
- installs a systemd service;
- enables it at boot;
- performs a local DNS query before reporting success.

The public interface is not intentionally bound on port 53.

## 2. Record both Tailscale DNS IPs

On each server:

```bash
tailscale ip -4 | head -n1
```

Keep both `100.x.x.x` addresses.

## 3. Configure Tailscale DNS

In the Tailscale admin console:

1. Open **DNS**.
2. Under **Nameservers**, add a **Custom** nameserver for the KR `100.x.x.x` address.
3. Add another **Custom** nameserver for the US `100.x.x.x` address.
4. Enable **Override DNS servers**.
5. Keep **MagicDNS** enabled if tailnet hostnames are used.

The two global resolvers are redundant.  Do not rely on a strict primary/secondary order: clients may select or race resolvers.  This is safe because both forward to the same Cloudflare Gateway policy.

## 4. Android / Galaxy

When this Tailscale DNS design is enabled:

```text
Settings
-> Connections
-> More connection settings
-> Private DNS
-> Automatic
```

In the Tailscale app, keep **Use Tailscale DNS settings** enabled.

Do not also force a separate Android Private DNS hostname while testing this setup.  That creates a second DNS control plane and is the configuration that previously produced "Private DNS server cannot be accessed" on some networks.

## 5. iPhone / iPad / Mac

Keep the normal Tailscale DNS setting enabled.  No separate DNS profile is required for this design.

## 6. Server service operations

Status:

```bash
sudo systemctl status tailscale-dnsproxy --no-pager
```

Recent logs:

```bash
sudo journalctl -u tailscale-dnsproxy -n 100 --no-pager
```

Follow logs:

```bash
sudo journalctl -u tailscale-dnsproxy -f
```

Listening socket:

```bash
sudo ss -lntup | grep ':53'
```

Restart:

```bash
sudo systemctl restart tailscale-dnsproxy
```

## 7. DNS verification

On a relay itself:

```bash
TS_IP="$(tailscale ip -4 | head -n1)"
dig @"$TS_IP" example.com A +short
```

From another tailnet device with `dig`:

```bash
dig @100.x.x.x example.com A
```

To inspect whether a known blocked hostname is filtered:

```bash
dig @100.x.x.x app-measurement.com A
```

Cloudflare policy settings determine whether a blocked query returns NXDOMAIN, a block IP, or another blocked response.

## 8. Automatic filter refresh

GitHub Actions workflow:

```text
.github/workflows/update-cf-gateway.yml
```

Current schedule:

```text
00:17 KST
12:17 KST
```

Current maintained sources:

- HaGeZi Multi Normal
- AdGuard DNS filter
- KOR: YousList
- KOR: filterslists-KO
- HaGeZi Samsung Native
- local curated supplement in `lists/dongri-extra-blocklist.txt`

The workflow verifies that the local high-value rules survive list merging before it changes Cloudflare Gateway.  A failed verification stops the deployment rather than silently publishing an incomplete list.

## 9. Local curated supplement

`lists/dongri-extra-blocklist.txt` is intentionally small.  It records high-value app/tracker endpoints observed in the supplied NextDNS screenshots, including NAVER/Kakao ad telemetry and common app telemetry.

Current entries include:

```text
wcs.naver.com
serv.ds.kakao.com
ka.ds.kakao.com
tr.ds.kakao.com
kakaoad.com
app-ad.tiara.kakao.com
incoming.telemetry.mozilla.org
app-measurement.com
```

Cloudflare's Domain matching covers the named domain and its subdomains, so wildcard syntax is unnecessary in the Gateway domain policy.

Do not casually add broad parent domains such as `kakao.com`, `naver.com`, or `googleapis.com`; DNS filtering cannot distinguish an ad request from a required API request on the same hostname.

## 10. Troubleshooting

### curl: (23) Failure writing output to destination

An older installer parsed the GitHub release JSON with a `curl | awk ... exit` pipeline while `pipefail` was enabled.  After `awk` found `tag_name`, it closed the pipe early, so curl reported error 23 (EPIPE).

The installer now downloads the complete release JSON first and parses the local file.  Re-running the current installer fixes this; the error was not evidence that disk space or the KR/US network was broken.

### Service will not start

Run:

```bash
sudo systemctl status tailscale-dnsproxy --no-pager
sudo journalctl -u tailscale-dnsproxy -n 100 --no-pager
sudo ss -lntup | grep ':53'
```

Common causes are another process binding the same Tailscale address/port, an invalid DoH URL, or the tailnet being disconnected.

### Ads still appear

DNS filtering can block requests made to dedicated ad/tracker hostnames.  It cannot reliably remove:

- first-party ads served from the same hostname as app content;
- cosmetic empty spaces after an ad request is blocked;
- YouTube in-stream ads served from shared media infrastructure.

Those require app/browser-level filtering rather than more DNS entries.

## 11. Rebuild checklist

If both servers are replaced:

1. install Tailscale and join the tailnet;
2. on KR, restore/start the existing Docker AdGuard Home stack and run `configure-kr-adguard-gateway.sh`;
3. on US, run `install-tailscale-dns-relay.sh`;
4. record both new `100.x` addresses;
5. add both addresses as Global nameservers in Tailscale DNS;
6. enable Override DNS servers;
7. set Galaxy Private DNS to Automatic and keep Tailscale DNS enabled;
8. run the GitHub filter workflow manually once;
9. verify normal DNS and one known blocked domain against both resolvers;
10. if selective Korean ISP-block bypass is desired, install `install-tailscale-warning-bypass.sh` on US only.


## 12. Availability-first / fail-open behavior

This setup is intentionally biased toward **keeping Internet access available**.

Each KR/US relay uses the Cloudflare Gateway DoH endpoint as its normal upstream. If that upstream is unavailable or returns a transport-level failure, `dnsproxy` falls back to encrypted public DNS:

```text
https://cloudflare-dns.com/dns-query
https://dns.google/dns-query
```

That means:

- normal state: Cloudflare Gateway filtering is enforced;
- Gateway outage / TLS failure / upstream transport failure: DNS still works, but ad-blocking can temporarily be bypassed;
- a domain that Cloudflare Gateway intentionally blocks is still treated as a valid DNS response and does **not** trigger fallback.

The two independent Tailscale DNS relays (KR + US) add another layer of redundancy.

### Android VPN lockdown setting

Tailscale without an Exit Node is a split-tunnel VPN. On Android, **Block connections without VPN** (VPN lockdown mode) should be **OFF** if no Exit Node is selected. If lockdown is ON, Android can force all Internet traffic into the Tailscale VPN interface even though Tailscale is not acting as a full Internet gateway, which can make the Internet appear blocked.

Samsung / Galaxy path (wording may vary by One UI version):

```text
Settings
-> Connections
-> More connection settings
-> VPN
-> gear icon next to Tailscale
-> Block connections without VPN = OFF
```

`Always-on VPN` may remain enabled if desired; the important setting for split-tunnel use is that `Block connections without VPN` is disabled unless an Exit Node is intentionally being used.

### Tailscale "DNS unavailable" health warning

A separate Android Tailscale warning named **DNS unavailable** can be shown when a custom/private tailnet DNS resolver is configured, even when DNS queries actually work. This is a Tailscale Android health-check/UI issue and cannot be safely suppressed from the DNS server configuration.

Do not hide this warning by weakening routing or forcing an Exit Node. Instead verify actual DNS reachability:

```bash
dig @<KR_OR_US_TAILSCALE_IP> example.com A +short
```

If DNS works and ordinary Internet access works, the warning may be cosmetic. If DNS actually fails, check both relay services and Tailscale reachability.



## KR node: existing Docker DNS stack

The KR node already has a working Docker-based DNS stack and must **not** run the host-level `tailscale-dnsproxy.service`.

Observed working listener:

```text
KR Tailscale DNS: 100.121.219.35:53
container: adguardhome
image: adguard/adguardhome:latest
```

A direct query to `100.121.219.35:53` returned a normal `NOERROR` response, so this address is already suitable as the KR Tailscale nameserver.

Also present:

```text
dns-forwarder
image: adguard/dnsproxy:latest
upstreams:
  tls://YOUR-ID.cloudflare-gateway.com
  https://YOUR-ID.cloudflare-gateway.com/dns-query
  172.64.36.1
  172.64.36.2
  [2a06:98c1:54::23:3b18]
fallback:
  129.154.52.136
```

The AdGuard Home listener and the `dns-forwarder` container are part of the existing KR deployment and must not be removed by the host-relay cleanup.

### Clean up the failed host-level relay attempt on KR

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/cleanup-host-tailscale-dns-relay.sh \
  -o /tmp/cleanup-host-tailscale-dns-relay.sh && \
sudo bash /tmp/cleanup-host-tailscale-dns-relay.sh
```

This removes only artifacts created by `install-tailscale-dns-relay.sh`:

- `tailscale-dnsproxy.service`
- `/usr/local/libexec/tailscale-dnsproxy-run`
- `/etc/tailscale-dnsproxy`
- the standalone host `/usr/local/bin/dnsproxy` when no other systemd unit references it

It intentionally leaves Docker and the existing DNS containers untouched.


## Post-cleanup sequence for the current deployment

Current known resolver addresses:

```text
KR  100.121.219.35  -> existing Docker AdGuard Home
US  100.94.3.111    -> host-level tailscale-dnsproxy
```

After cleaning the failed KR host-level relay attempt:

### A. Point KR AdGuard Home at the same Cloudflare Gateway policy

Run on KR:

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/configure-kr-adguard-gateway.sh \
  -o /tmp/configure-kr-adguard-gateway.sh && \
sudo env DOH_URL='https://YOUR-ID.cloudflare-gateway.com/dns-query' \
  bash /tmp/configure-kr-adguard-gateway.sh
```

The script backs up `AdGuardHome.yaml`, makes Cloudflare Gateway the sole normal upstream, sets encrypted Cloudflare + Google DoH as fail-open fallbacks, restarts AdGuard Home, and verifies DNS through the KR Tailscale address.

The existing `dns-forwarder` container is left untouched because it may still serve `dns.dongri.me` / external DoT/DoH paths.

### B. Verify both resolvers

```bash
dig @100.121.219.35 example.com A +short
dig @100.94.3.111 example.com A +short

dig @100.121.219.35 app-measurement.com A
dig @100.94.3.111 app-measurement.com A
```

Both normal queries must resolve.  The tracker query should show the Cloudflare Gateway block behavior configured for the account.

### C. Tailscale admin DNS

Add both as Global / Custom nameservers:

```text
100.121.219.35
100.94.3.111
```

Enable **Override DNS servers**.  Keep MagicDNS enabled if tailnet hostnames are used.

### D. Clients

Galaxy:

```text
Android Private DNS = Automatic
Tailscale -> Use Tailscale DNS settings = On
Exit Node = None
Block connections without VPN = Off
```

iPhone / iPad / macOS:

```text
Tailscale DNS = On
Exit Node = None
```

Android, iOS, macOS, tvOS, and Windows accept Tailscale subnet routes by default. Linux clients need `tailscale set --accept-routes=true`.

### E. Selective `warning.or.kr` bypass

Install only on US after DNS is confirmed:

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/install-tailscale-warning-bypass.sh \
  -o /tmp/install-tailscale-warning-bypass.sh && \
sudo bash /tmp/install-tailscale-warning-bypass.sh
```

Then ensure the US node's advertised subnet routes are approved (or covered by an `autoApprovers.routes` policy).  Clients keep **Exit Node = None**; only matching destination IPs use the US subnet router.



## 14. Repoint KR AdGuard Home to the existing Cloudflare Gateway forwarder

The existing KR AdGuard Home listener originally used multiple public resolvers
in parallel.  To make KR and US apply the same Cloudflare Gateway policy, use
the existing `dns-forwarder` container as the sole AdGuard Home upstream.

Run on KR:

```bash
curl -fsSL https://raw.githubusercontent.com/catgarret/cf-dnsAdblocker/main/scripts/configure-kr-adguard-upstream.sh \
  -o /tmp/configure-kr-adguard-upstream.sh && \
sudo bash /tmp/configure-kr-adguard-upstream.sh
```

The helper auto-detects the current `dns-forwarder` container IP, tests it,
backs up `AdGuardHome.yaml`, replaces only `upstream_dns`, restarts the
container, and verifies DNS through the KR Tailscale address.

At the time of inspection, the forwarder address was `172.19.0.6`, but the
script intentionally re-detects it because Docker bridge addresses can change
after recreation.

A previous test of `app-measurement.com` through KR returned `0.0.0.0`.
That confirms filtering at the AdGuard Home layer, but does not by itself prove
that the query traversed Cloudflare Gateway; repointing the upstream makes the
Gateway path deterministic.
