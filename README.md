# WHERE-IS-SNI

> A domain pool & scoring tool for finding optimal SNI domains for REALITY protocol.

---

## 🇨🇳 中文说明

### 简介

`WHERE-IS-SNI` 提供一个包含 **399 个**候选域名的池子和一个 Bash 评分脚本，帮助你为 Xray REALITY 协议找到最优 SNI。

### 文件说明

| 文件 | 说明 |
|------|------|
| `domains.txt` | 399 个候选域名，覆盖全球各地理区域和行业 |
| `sni-finder.sh` | 自动测试脚本：随机抽取、检测、评分、输出 JSON |

### 使用方法

```bash
# 1. 在 Linux 服务器上下载
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# 2. 给脚本执行权限
chmod +x sni-finder.sh

# 3. 直接运行（随机检测 10 个域名）
bash sni-finder.sh

# 4. 指定检测数量
bash sni-finder.sh -n 5

# 5. 指定超时时间（秒）
bash sni-finder.sh -t 3

# 6. 自定义域名列表
bash sni-finder.sh -l my-domains.txt

# 7. 输出到文件
bash sni-finder.sh -o result.json

# 8. 显示详细进度
bash sni-finder.sh -v

# 9. 组合使用
bash sni-finder.sh -n 8 -t 4 -o result.json -v
```

### 检测指标与评分权重

| 指标 | 权重 | 说明 |
|------|------|------|
| TCP 连通性 | 25% | 不同则整条记 0 分 |
| 延迟 | 20% | ping + TLS 握手综合耗时 |
| TLS 版本 | 15% | 1.3 满分，1.2 折半 |
| 证书链大小 | 15% | 越小越高分 |
| 密钥类型 | 15% | ECDSA 优先 |
| DNS 解析 | 10% | 越快越高分 |

### JSON 输出示例

```json
{
  "tool": "sni-finder.sh",
  "version": "1.0.0",
  "timestamp": "2026-06-24T10:30:00Z",
  "best_sni": "notion.so",
  "pool_size": 399,
  "sample_size": 10,
  "results": [
    {
      "sni": "notion.so",
      "score": 88,
      "reachable": true,
      "tls_version": "TLSv1.3",
      "tls_ms": 45,
      "ping_ms": 12,
      "cert_size_bytes": 2861,
      "cert_chain_len": 2,
      "key_type": "ECDSA",
      "issuer": "DigiCert Inc",
      "dns_ms": 5
    }
  ]
}
```

### 依赖

| 工具 | 用途 | 是否预装 |
|------|------|----------|
| `openssl` | TLS 握手检测 | ✅ 大多数 Linux 默认安装 |
| `ping` | ICMP 延迟测试 | ✅ 默认安装 |
| `getent` | DNS 解析 | ✅ glibc 自带 |
| `shuf` | 随机抽取 | ✅ GNU coreutils 自带 |
| `timeout` | 超时控制 | ✅ GNU coreutils 自带 |

### 域名池覆盖

- 国际开源与开发者工具（25）
- 海外知名高校与科研机构（25）
- 开源媒体、设计、文档（20）
- 海外云服务与 IT 基础设施（20）
- 非营利组织与开放标准（10）
- 日本：电商 / 社区 / 大学 / 政府 / 企业（49）
- 香港：社区 / 大学 / 政府 / 金融 / 航空（50）
- 韩国：电商 / 社区 / 大学 / 政府 / 金融（50）
- 新加坡：电商 / 大学 / 政府 / 金融 / 航空（50）
- 马来西亚（20）
- 英国（30）
- 欧洲大陆（30）
- 美国（20）

---

## 🇬🇧 English

### Introduction

`WHERE-IS-SNI` provides a curated pool of **399 candidate domains** and a Bash scoring script to help you find the optimal SNI for the Xray REALITY protocol.

### Files

| File | Description |
|------|-------------|
| `domains.txt` | 399 candidate domains covering global regions and industries |
| `sni-finder.sh` | Auto-test script: random pick, probe, score, JSON output |

### Usage

```bash
# 1. Clone on your Linux server
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# 2. Make it executable
chmod +x sni-finder.sh

# 3. Run directly (random 10 domains)
bash sni-finder.sh

# 4. Specify sample size
bash sni-finder.sh -n 5

# 5. Custom timeout (seconds)
bash sni-finder.sh -t 3

# 6. Custom domain list file
bash sni-finder.sh -l my-domains.txt

# 7. Output to file
bash sni-finder.sh -o result.json

# 8. Verbose progress
bash sni-finder.sh -v

# 9. Combine options
bash sni-finder.sh -n 8 -t 4 -o result.json -v
```

### Scoring Breakdown

| Metric | Weight | Description |
|--------|--------|-------------|
| TCP connectivity | 25% | Score 0 if unreachable |
| Latency | 20% | ping + TLS handshake combined |
| TLS version | 15% | 1.3 full score, 1.2 half |
| Cert chain size | 15% | Smaller = better |
| Key type | 15% | ECDSA preferred |
| DNS resolution | 10% | Faster = better |

### Dependencies

| Tool | Purpose | Pre-installed |
|------|---------|---------------|
| `openssl` | TLS handshake | ✅ Most Linux distros |
| `ping` | ICMP latency | ✅ Default |
| `getent` | DNS resolution | ✅ glibc |
| `shuf` | Random selection | ✅ GNU coreutils |
| `timeout` | Timeout control | ✅ GNU coreutils |

### Domain Pool Coverage

- International open source & developer tools (25)
- Overseas universities & research (25)
- Open source media, design & documentation (20)
- Cloud services & IT infrastructure (20)
- Non-profit & open standards (10)
- Japan: e-commerce / community / university / government / enterprise (49)
- Hong Kong: community / university / government / finance / aviation (50)
- Korea: e-commerce / community / university / government / finance (50)
- Singapore: e-commerce / university / government / finance / aviation (50)
- Malaysia (20)
- United Kingdom (30)
- Continental Europe (30)
- United States (20)

---

## 🇮🇷 توضیحات فارسی

### مقدمه

`WHERE-IS-SNI` یک مجموعه از **۳۹۹ دامنه** و یک اسکریپت Bash برای یافتن بهترین SNI برای پروتکل REALITY در Xray است.

### فایل‌ها

| فایل | توضیحات |
|------|---------|
| `domains.txt` | ۳۹۹ دامنه کاندید از مناطق و صنایع مختلف جهان |
| `sni-finder.sh` | اسکریپت تست خودکار: انتخاب تصادفی، بررسی، امتیازدهی، خروجی JSON |

### نحوه استفاده

```bash
# ۱. کلون کردن روی سرور لینوکسی
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# ۲. اجرایی کردن اسکریپت
chmod +x sni-finder.sh

# ۳. اجرای مستقیم (۱۰ دامنه تصادفی)
bash sni-finder.sh

# ۴. تعیین تعداد دامنه
bash sni-finder.sh -n 5

# ۵. تعیین زمان انتظار (ثانیه)
bash sni-finder.sh -t 3

# ۶. استفاده از لیست دامنه شخصی
bash sni-finder.sh -l my-domains.txt

# ۷. ذخیره خروجی در فایل
bash sni-finder.sh -o result.json

# ۸. نمایش جزئیات پیشرفت
bash sni-finder.sh -v

# ۹. ترکیب گزینه‌ها
bash sni-finder.sh -n 8 -t 4 -o result.json -v
```

### معیارهای امتیازدهی

| معیار | وزن | توضیحات |
|-------|------|---------|
| اتصال TCP | ۲۵٪ | در صورت عدم اتصال امتیاز صفر |
| تأخیر | ۲۰٪ | مجموع ping و TLS handshake |
| نسخه TLS | ۱۵٪ | ۱.۳ امتیاز کامل، ۱.۲ نصف |
| اندازه زنجیره گواهی | ۱۵٪ | کوچکتر = بهتر |
| نوع کلید | ۱۵٪ | ECDSA اولویت دارد |
| DNS | ۱۰٪ | سریعتر = بهتر |

### وابستگی‌ها

| ابزار | کاربرد | نصب پیش‌فرض |
|-------|--------|-------------|
| `openssl` | بررسی TLS | ✅ در اکثر توزیع‌های لینوکس |
| `ping` | تست تأخیر ICMP | ✅ پیش‌فرض |
| `getent` | DNS | ✅ glibc |
| `shuf` | انتخاب تصادفی | ✅ GNU coreutils |
| `timeout` | کنترل زمان انتظار | ✅ GNU coreutils |

### پوشش دامنه‌ها

- ابزارهای متن‌باز و توسعه (۲۵)
- دانشگاه‌ها و مراکز تحقیقاتی (۲۵)
- رسانه و محتوای متن‌باز (۲۰)
- سرویس‌های ابری و زیرساخت IT (۲۰)
- سازمان‌های غیرانتفاعی (۱۰)
- ژاپن (۴۹)
- هنگ‌کنگ (۵۰)
- کره جنوبی (۵۰)
- سنگاپور (۵۰)
- مالزی (۲۰)
- بریتانیا (۳۰)
- اروپا (۳۰)
- آمریکا (۲۰)
