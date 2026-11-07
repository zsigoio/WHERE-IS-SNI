# WHERE-IS-SNI

[English](../README.md) | [中文](README_CN.md) | [فارسی](README_FA.md) | [Русский](README_RU.md)

从 [域名池](../domains.txt) 抽样或全量筛查 Xray REALITY 的公网目标。需要 Go 1.25+ 和系统 CA 证书库。通过脚本运行还需要 Bash，一键下载需要 curl。

## 在 Linux 服务器上安装 Go

先在服务器上运行 `go version`。如果提示找不到命令，或者版本低于 1.25，在 Bash 中运行下面的命令。它会识别 x86-64 或 ARM64，下载 Go 官方发行包并安装到当前用户目录，无需 sudo。 [Go 官方安装说明](https://go.dev/doc/install) · [官方下载页](https://go.dev/dl/)

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

如果希望重新 SSH 登录后也能使用 Go，把 `export PATH="$HOME/.local/opt/sni-go/current/bin:$PATH"` 加到 `~/.profile`。请用同一个用户运行下面的 SNI 脚本。

## 使用

```bash
# 默认随机检测 15 个目标
bash sni-finder.sh

# 全库审计，保留每个目标的判定与原因
bash sni-finder.sh --all --no-menu -j 24 -o audit.json

# 复现面板中分开填写的 Target 和 SNI
bash sni-finder.sh --no-menu --sni www.example.org 203.0.113.10:443

# 一键下载并运行已发布的版本
bash <(curl -fsSL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh)
```

Windows 在仓库根目录运行 `go run .\sni-finder.go --all --no-menu -o audit.json`。用 `-h` 查看选项，并把选项写在目标前。目标可写为域名或 `host:port`，默认端口为 443。如果目标要求 PROXY 协议，按面板设置指定 `--xver 1` 或 `--xver 2`。

交互菜单可以重新探测、按实测 IP 查询并分组查看国家、应用最优合格目标。使用 `-y --xray-config PATH` 可直接应用。脚本会检查入站的 `xver`、备份配置并更新 REALITY 入站，有运行中的 Xray 或 V2Ray systemd 服务时会重启对应服务。

## 如何判定

- 当前 3x-ui 在同一次握手中要求 TLS 1.3、ALPN `h2`、X25519 或 X25519MLKEM768，以及对所填 SNI 有效的可信证书。脚本采用相同的握手门槛，并额外排除 DNS 结果包含 Cloudflare CDN 或非公网地址的目标。 [3x-ui 探测源码](https://github.com/MHSanaei/3x-ui/blob/main/internal/web/service/reality_scan.go) · [Cloudflare 官方网段](https://www.cloudflare.com/ips/)
- 握手只协商到 TLS 1.2 会得到 `tls_below_1_3`。同时支持 TLS 1.2 和 1.3 的站点，只要本次协商到 TLS 1.3 且满足其余条件，就能入选。
- JSON 保留所有受测目标。查看 `eligible`、`reasons`、`resolved_ips` 和实际连接的 `ip`。`reachable` 表示 TLS 握手已完成。全部失败时 `best_sni` 和 `best_target` 为空。
- 分数只用于合格目标排序。延迟按 TCP + TLS 耗时计分，`--max-latency` 只影响延迟得分。`ping_ms` 保留为 `-1` 供旧的 JSON 消费方读取。

本机与 VPS 的 DNS、IPv4/IPv6 路由、出口过滤和 CA 证书库可能不同，即使忽略耗时，连通性和握手判定也可能不同。应在运行 3x-ui 的主机或容器里，用面板中的 Target、SNI 和 xver 复测。
