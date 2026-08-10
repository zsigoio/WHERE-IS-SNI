# WHERE-IS-SNI — 中文说明

> 为 Xray REALITY 协议寻找最优 SNI 域名的域名池与评分工具。

---

## 简介

`WHERE-IS-SNI` 提供一个包含 **693 个**候选域名的池子和一个 Bash 评分脚本，帮助你为 Xray REALITY 协议找到最优 SNI。

## 文件说明

| 文件 | 说明 |
|------|------|
| `domains.txt` | 693 个候选域名，覆盖全球各地理区域和行业 |
| `sni-finder.sh` | 自动测试脚本：随机抽取、检测、评分、输出 JSON |
| `sni-finder-run.sh` | 一键安装运行脚本（curl 直用） |
| `.gitignore` | 忽略本地配置文件 |

## 使用方法

**一键运行（随机 15 个）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh)
```

**测试指定域名：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh) shopee.vn tiki.vn sendo.vn
```

或先下载到本地：
```bash
# 1. 在 Linux 服务器上下载
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# 2. 给脚本执行权限
chmod +x sni-finder.sh

# 3. 直接运行（随机检测 15 个域名）
bash sni-finder.sh

# 4. 测试指定域名
bash sni-finder.sh www.samsung.com www.sony.com www.intel.com

# 5. 指定检测数量
bash sni-finder.sh -n 5

# 6. 指定超时时间（秒）
bash sni-finder.sh -t 3

# 7. 自定义域名列表
bash sni-finder.sh -l my-domains.txt

# 8. 输出到文件
bash sni-finder.sh -o result.json

# 9. 跳过菜单直接应用最优 SNI
bash sni-finder.sh -y

# 10. 只输出 JSON，跳过菜单
bash sni-finder.sh --no-menu

# 11. 指定 Xray 配置文件路径
bash sni-finder.sh -y --xray-config /etc/xray/config.json

# 12. 显示详细进度
bash sni-finder.sh -v

# 13. 组合使用
bash sni-finder.sh -n 8 -t 4 -o result.json -v

# 14. 指定域名 + 自动应用
bash sni-finder.sh -y www.cloudflare.com www.fastly.com
```

## 交互菜单

运行后出现四个选项：

```
 0) Exit
 1) Re-test with new random domains
 2) Apply 'best-sni' to Xray config and restart
 3) Browse domains by country
```

- **0** — 退出
- **1** — 重新随机抽选域名测试（若使用指定域名模式则重新测试相同域名）
- **2** — 将最优 SNI 写入 Xray 配置（自动备份原文件）并重启服务
- **3** — 按国家/地区分类浏览测试结果（通过 ip.im 查询 GeoIP）

## 检测指标与评分权重

| 指标 | 权重 | 说明 |
|------|------|------|
| TCP 连通性 | 25% | 不同则整条记 0 分 |
| 延迟 | 20% | ping + TLS 握手综合耗时 |
| TLS 版本 | 12% | 1.3 满分（12），1.2 仅 3 分 |
| ALPN h2 | 8% | h2 满分（8），仅 http/1.1 得 3 分 |
| 密钥交换 | 10% | X25519MLKEM768 满分（10），X25519 得 7 分 |
| 证书链大小 | 10% | 越小越高分 |
| 密钥类型 | 10% | ECDSA 满分（10），RSA 得 6 分 |
| DNS 解析 | 5% | 越快越高分 |

> ⚠️ **Cloudflare 域名直接判 0 分**：DNS 解析出的 IP（含 IPv6）落在 Cloudflare CDN 段内（[官方 IP 列表](https://www.cloudflare.com/ips-v4)）的域名，直接跳过所有测试、总分记 0。防止回退流量被 CF 劫持/偷跑。

## JSON 输出示例

```json
{
  "tool": "sni-finder.sh",
  "version": "1.0.0",
  "timestamp": "2026-06-24T10:30:00Z",
  "best_sni": "notion.so",
  "pool_size": 693,
  "sample_size": 15,
  "results": [
    {
      "sni": "columbia.edu",
      "score": 94,
      "reachable": true,
      "cloudflare": false,
      "tls_version": "TLSv1.3",
      "alpn": "h2",
      "kex": "MLKEM768",
      "tls_ms": 45,
      "ping_ms": 12,
      "cert_size_bytes": 3574,
      "cert_chain_len": 3,
      "key_type": "ECDSA",
      "issuer": "C=US",
      "dns_ms": 5
    }
  ]
}
```

## 依赖

| 工具 | 用途 | 是否预装 |
|------|------|----------|
| `openssl` | TLS 握手检测 | ✅ 大多数 Linux 默认安装 |
| `ping` | ICMP 延迟测试 | ✅ 默认安装 |
| `getent` | DNS 解析 | ✅ glibc 自带 |
| `shuf` | 随机抽取 | ✅ GNU coreutils 自带 |
| `timeout` | 超时控制 | ✅ GNU coreutils 自带 |

## 域名池覆盖

> 详见 `domains.txt`
