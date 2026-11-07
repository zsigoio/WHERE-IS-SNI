# WHERE-IS-SNI

[English](README/README_EN.md) | [中文](README/README_CN.md) | [فارسی](README/README_FA.md) | [Русский](README/README_RU.md)

Find and audit public TLS targets for Xray REALITY. The candidate pool is in [domains.txt](domains.txt).

## Install Go on Linux

Run `go version` on the server first. If Go is missing or older than 1.25, use Bash to download the official release for x86-64 or ARM64 and install it under your user account. [Go installation guide](https://go.dev/doc/install) · [Official downloads](https://go.dev/dl/)

```bash
(
  set -eu
  case "$(uname -m)" in
    x86_64) go_arch=amd64 ;;
    aarch64|arm64) go_arch=arm64 ;;
    *) echo "See https://go.dev/dl/ for this architecture." >&2; exit 1 ;;
  esac

  go_release=$(curl -fsSL 'https://go.dev/VERSION?m=text')
  go_version=${go_release%%$'\n'*}
  [[ $go_version =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
  go_dir="$HOME/.local/opt/sni-go"
  mkdir -p "$go_dir"

  if [ ! -x "$go_dir/$go_version/bin/go" ]; then
    work_dir=$(mktemp -d "$go_dir/.install.XXXXXX")
    trap 'rm -f "$work_dir/go.tar.gz"; rmdir "$work_dir" 2>/dev/null || true' EXIT
    curl -fsSL "https://go.dev/dl/$go_version.linux-$go_arch.tar.gz" -o "$work_dir/go.tar.gz"
    tar -xzf "$work_dir/go.tar.gz" -C "$work_dir"
    mv -T "$work_dir/go" "$go_dir/$go_version"
  fi
  ln -sfnT "$go_version" "$go_dir/current"
) && export PATH="$HOME/.local/opt/sni-go/current/bin:$PATH" && go version
```

To keep Go on your PATH in new SSH sessions, add `export PATH="$HOME/.local/opt/sni-go/current/bin:$PATH"` to `~/.profile`. Run the commands below as the same user.

## Run

The probe requires Go 1.25+ and a system CA store. The shell launchers also need Bash, and the download launcher needs curl. The Go probe uses only the standard library.

```bash
# Random sample from the bundled pool
bash sni-finder.sh

# Full audit with failure reasons
bash sni-finder.sh --all --no-menu -j 24 -o audit.json

# Explicit target and SNI, matching the values entered in the panel
bash sni-finder.sh --no-menu --sni www.example.org 203.0.113.10:443

# Download and run the published version
bash <(curl -fsSL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh)
```

On Windows, run the probe directly from the repository root.

```powershell
go run .\sni-finder.go --all --no-menu -o audit.json
```

Use `-h` to list options. Put options before targets. Bare hosts use port 443. If the target expects a PROXY header, pass the panel's `--xver 1` or `--xver 2`.

The interactive menu can resample, apply the best eligible result, or group results by country using the tested IP. To apply without a menu, use `-y --xray-config PATH`. Apply updates REALITY inbounds using the exact target and SNI that passed the probe, checks their `xver`, backs up the config, and restarts an active Xray or V2Ray systemd service when present.

## Eligibility and ranking

The probe mirrors the TLS checks of the current 3x-ui scanner. One handshake must negotiate TLS 1.3, ALPN `h2`, and X25519 or X25519MLKEM768, with a certificate trusted for the supplied SNI. A server that negotiates TLS 1.3 can also offer TLS 1.2 to legacy clients. The pool also excludes names whose resolved addresses include a Cloudflare CDN IP or a non-public IP. [3x-ui scanner](https://github.com/MHSanaei/3x-ui/blob/main/internal/web/service/reality_scan.go) · [Cloudflare IP ranges](https://www.cloudflare.com/ips/)

Every sampled target appears in JSON with `eligible`, `reasons`, the resolved addresses, and handshake details when available. `best_sni` and `best_target` are empty if all targets fail. `reachable` indicates a completed TLS handshake. `ping_ms` is retained as `-1` for compatibility. Eligible scores retain the original weights, using TCP plus TLS latency for the 20 latency points. `--max-latency` limits those points without changing eligibility.

DNS answers, address ordering, routing, egress filtering, and trusted CAs can differ between a workstation and the VPS. Compare the same target, SNI, and xver from the machine or container running 3x-ui. Use the audit's resolved and connected IPs to explain discrepancies.
