# WHERE-IS-SNI — توضیحات فارسی

> یک مجموعه دامنه و ابزار امتیازدهی برای یافتن بهترین SNI برای پروتکل REALITY.

---

## مقدمه

`WHERE-IS-SNI` یک مجموعه از **۶۹۳ دامنه** و یک اسکریپت Bash برای یافتن بهترین SNI برای پروتکل REALITY در Xray است.

## فایل‌ها

| فایل | توضیحات |
|-------|---------|
| `domains.txt` | ۶۹۳ دامنه کاندید از مناطق و صنایع مختلف جهان |
| `sni-finder.sh` | اسکریپت تست خودکار: انتخاب تصادفی، بررسی، امتیازدهی، خروجی JSON |
| `sni-finder-run.sh` | اسکریپت نصب و اجرای یک‌خطی |
| `.gitignore` | نادیده گرفتن فایل‌های کانفیگ محلی |

## نحوه استفاده

**اجرای یک‌خطی (۱۵ دامنه تصادفی):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh)
```

**تست دامنه‌های مشخص:**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zsigoio/WHERE-IS-SNI/main/sni-finder-run.sh) shopee.vn tiki.vn sendo.vn
```

یا کلون کردن:
```bash
# ۱. کلون کردن روی سرور لینوکسی
git clone https://github.com/zsigoio/WHERE-IS-SNI.git
cd WHERE-IS-SNI

# ۲. اجرایی کردن اسکریپت
chmod +x sni-finder.sh

# ۳. اجرای مستقیم (۱۵ دامنه تصادفی)
bash sni-finder.sh

# ۴. تست دامنه‌های مشخص
bash sni-finder.sh www.samsung.com www.sony.com www.intel.com

# ۵. تعیین تعداد دامنه
bash sni-finder.sh -n 5

# ۶. تعیین زمان انتظار (ثانیه)
bash sni-finder.sh -t 3

# ۷. استفاده از لیست دامنه شخصی
bash sni-finder.sh -l my-domains.txt

# ۸. ذخیره خروجی در فایل
bash sni-finder.sh -o result.json

# ۹. اعمال خودکار SNI برتر، رد کردن منو
bash sni-finder.sh -y

# ۱۰. فقط خروجی JSON، بدون منو
bash sni-finder.sh --no-menu

# ۱۱. تعیین مسیر کانفیگ Xray
bash sni-finder.sh -y --xray-config /etc/xray/config.json

# ۱۱. نمایش جزئیات پیشرفت
bash sni-finder.sh -v

# ۱۲. ترکیب گزینه‌ها
bash sni-finder.sh -n 8 -t 4 -o result.json -v
```

## منوی تعاملی

پس از تست، چهار گزینه نمایش داده می‌شود:

```
 0) خروج
 1) تست مجدد با دامنه‌های تصادفی جدید
 2) اعمال SNI برتر در کانفیگ Xray و راه‌اندازی مجدد
 3) مرور دامنه‌ها بر اساس کشور
```

- **۰** — خروج
- **۱** — انتخاب تصادفی دامنه‌های جدید و تست مجدد
- **۲** — نوشتن بهترین SNI در کانفیگ Xray (پشتیبان‌گیری خودکار) و راه‌اندازی مجدد سرویس
- **۳** — مرور نتایج تست بر اساس کشور (GeoIP از طریق ip.im)

## معیارهای امتیازدهی

| معیار | وزن | توضیحات |
|-------|------|---------|
| اتصال TCP | ۲۵٪ | در صورت عدم اتصال امتیاز صفر |
| تأخیر | ۲۰٪ | مجموع ping و TLS handshake |
| نسخه TLS | ۱۲٪ | ۱.۳ امتیاز کامل (۱۲)، ۱.۲ فقط ۳ |
| ALPN h2 | ۸٪ | h2 کامل (۸)، فقط http/1.1 یعنی ۳ |
| تبادل کلید | ۱۰٪ | X25519MLKEM768 کامل (۱۰)، X25519 یعنی ۷ |
| اندازه زنجیره گواهی | ۱۰٪ | کوچکتر = بهتر |
| نوع کلید | ۱۰٪ | ECDSA کامل (۱۰)، RSA یعنی ۶ |
| DNS | ۵٪ | سریعتر = بهتر |

> ⚠️ **دامنه‌های Cloudflare امتیاز صفر**: دامنه‌هایی که IP آن‌ها (IPv4/IPv6) در محدوده CDN کلادفلر باشد ([لیست رسمی](https://www.cloudflare.com/ips-v4))، کاملاً رد شده و امتیاز صفر می‌گیرند تا از ربودن ترافیک fallback توسط CF جلوگیری شود.

## وابستگی‌ها

| ابزار | کاربرد | نصب پیش‌فرض |
|-------|--------|-------------|
| `openssl` | بررسی TLS | ✅ در اکثر توزیع‌های لینوکس |
| `ping` | تست تأخیر ICMP | ✅ پیش‌فرض |
| `getent` | DNS | ✅ glibc |
| `shuf` | انتخاب تصادفی | ✅ GNU coreutils |
| `timeout` | کنترل زمان انتظار | ✅ GNU coreutils |

## پوشش دامنه‌ها

> فهرست کامل در `domains.txt` موجود است.
