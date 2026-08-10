# WHERE-IS-SNI — English

> A domain pool & scoring tool for finding optimal SNI domains for REALITY protocol.

---

## Introduction

`WHERE-IS-SNI` provides a curated pool of **693 candidate domains** and a Bash scoring script to help you find the optimal SNI for the Xray REALITY protocol.

## Files

| File | Description |
|------|-------------|
| `domains.txt` | 693 candidate domains covering global regions and industries |
| `sni-finder.sh` | Auto-test script: random pick, probe, score, JSON output |
| `sni-finder-run.sh` | One-liner install & run script |
| `.gitignore` | Ignore local config files |

## Usage

**One-liner (random 15):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh)
```

**Test specific domains:**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh) shopee.vn tiki.vn sendo.vn
```

Or clone locally:
```bash
# 1. Clone on your Linux server
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# 2. Make it executable
chmod +x sni-finder.sh

# 3. Run directly (random 15 domains)
bash sni-finder.sh

# 4. Test specific domains
bash sni-finder.sh www.samsung.com www.sony.com www.intel.com

# 5. Specify sample size
bash sni-finder.sh -n 5

# 6. Custom timeout (seconds)
bash sni-finder.sh -t 3

# 7. Custom domain list file
bash sni-finder.sh -l my-domains.txt

# 8. Output to file
bash sni-finder.sh -o result.json

# 9. Auto-apply best SNI, skip menu
bash sni-finder.sh -y

# 10. JSON only, no menu
bash sni-finder.sh --no-menu

# 11. Specify Xray config path
bash sni-finder.sh -y --xray-config /etc/xray/config.json

# 12. Verbose progress
bash sni-finder.sh -v

# 13. Combine options
bash sni-finder.sh -n 8 -t 4 -o result.json -v

# 14. Specific domains + auto-apply
bash sni-finder.sh -y www.cloudflare.com www.fastly.com
```

## Interactive Menu

After testing, four options appear:

```
 0) Exit
 1) Re-test with new random domains
 2) Apply 'best-sni' to Xray config and restart
 3) Browse domains by country
```

- **0** — Exit
- **1** — Pick new random domains and re-test (or re-test same domains in specify mode)
- **2** — Write best SNI to Xray config (auto-backup) and restart service
- **3** — Browse tested results grouped by country (GeoIP via ip.im)

## Scoring Breakdown

| Metric | Weight | Description |
|--------|--------|-------------|
| TCP connectivity | 25% | Score 0 if unreachable |
| Latency | 20% | ping + TLS handshake combined |
| TLS version | 12% | 1.3 full (12), 1.2 only 3 |
| ALPN h2 | 8% | h2 full (8), http/1.1 only 3 |
| Key exchange | 10% | X25519MLKEM768 full (10), X25519 7 |
| Cert chain size | 10% | Smaller = better |
| Key type | 10% | ECDSA full (10), RSA 6 |
| DNS resolution | 5% | Faster = better |

> ⚠️ **Cloudflare domains score 0**: Domains whose DNS IPs (IPv4/IPv6) fall within Cloudflare CDN ranges ([official list](https://www.cloudflare.com/ips-v4)) are skipped entirely with score 0, to prevent fallback traffic from being hijacked by CF.

## Dependencies

| Tool | Purpose | Pre-installed |
|------|---------|---------------|
| `openssl` | TLS handshake | ✅ Most Linux distros |
| `ping` | ICMP latency | ✅ Default |
| `getent` | DNS resolution | ✅ glibc |
| `shuf` | Random selection | ✅ GNU coreutils |
| `timeout` | Timeout control | ✅ GNU coreutils |

## Domain Pool Coverage

> See `domains.txt` for full list.
