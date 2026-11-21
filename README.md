# Toolstunnel

**Interactive reverse-tunnel manager for Linux servers — one menu, three tunnel families.**

[English](#english) · [فارسی](#فارسی)

---

# English

Toolstunnel is a Bash script. It installs and manages open-source tunnel programs for you and creates a `systemd` service for every tunnel (auto-start, auto-restart).

```
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/Toolstunnel/main/install.sh)
```

Run it as **root** on **both** servers. Next time just run `toolstunnel`.

## What it can create

| Menu item | Types | Built on |
| --- | --- | --- |
| Stream tunnel | `tcpmux` `tcp` `ws` `wss` `wsmux` `wssmux` | [Backhaul](https://github.com/Musixal/Backhaul) |
| TUN tunnel | `tun-tcp` (fake-TCP) · `tun-udp` · `tun-icmp` | WireGuard + [udp2raw](https://github.com/wangyu-/udp2raw) |
| Kernel tunnel | `gre` · `ipip` · `sit` | Linux kernel (`ip tunnel`) |

A **TUN tunnel** gives both servers a private network (default `10.88.0.1` ↔ `10.88.0.2`) carried over fake-TCP, UDP or ICMP packets. You can optionally forward ports from the server side to the other side.

## How to use

1. Install on both servers.
2. On the listening server (usually Iran) choose **server**. On the other (usually abroad) choose **client**.
3. Use the same type, port and **token** on both sides. The script prints the values to copy.
4. Open the chosen port in the firewall of the server side.
5. Use **Manage tunnels → Test** to check the link.

## Notes

- Binaries are downloaded at install time from the official releases of each project; they are not stored in this repository. Their own licenses apply.
- TUN tunnels (udp2raw) currently need an **x86_64** server. Stream and kernel tunnels also work on ARM64.
- The **token** is a password: WireGuard keys are derived from it. Use the generated one (32 random characters).
- `tun-icmp` makes the server ignore normal pings while the tunnel runs.
- GRE/IPIP/SIT need your provider to allow those protocols between the two servers.
- The script does not forge source IP addresses.

## Not included (yet)

`kcp`, `anytls`, `http`/`https` mimicry and other names found in closed-source tools.

## License

MIT for this script. Backhaul, udp2raw and WireGuard have their own licenses.

---

# فارسی

Toolstunnel یک اسکریپت Bash است که برنامه‌های متن‌باز تونل را نصب و مدیریت می‌کند و برای هر تونل یک سرویس `systemd` می‌سازد (اجرای خودکار بعد از ریبوت و وصل‌شدن مجدد).

## نصب

```
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/Toolstunnel/main/install.sh)
```

روی **هر دو** سرور و با کاربر **root** اجرا کن. دفعهٔ بعد فقط بنویس: `toolstunnel`

## چه تونل‌هایی می‌سازد

| بخش منو | نوع‌ها | بر پایهٔ |
| --- | --- | --- |
| تونل جریانی (Stream) | `tcpmux` `tcp` `ws` `wss` `wsmux` `wssmux` | Backhaul |
| تونل TUN | `tun-tcp` (فیک‌تی‌سی‌پی) · `tun-udp` · `tun-icmp` | WireGuard + udp2raw |
| تونل کرنلی | `gre` · `ipip` · `sit` | خود کرنل لینوکس |

تونل **TUN** یک شبکهٔ خصوصی بین دو سرور می‌سازد (پیش‌فرض `10.88.0.1` ↔ `10.88.0.2`) که روی بسته‌های fake-TCP، UDP یا ICMP حرکت می‌کند. می‌توانی پورت‌ها را هم از سرور اول به سمت دوم فوروارد کنی.

## طرز استفاده

۱. روی هر دو سرور نصب کن.
۲. روی سروری که گوش می‌دهد (معمولاً ایران) گزینهٔ **server** و روی سرور دیگر (معمولاً خارج) گزینهٔ **client** را بزن.
۳. نوع، پورت و **توکن** باید روی هر دو یکی باشد. اسکریپت مقادیر را در پایان چاپ می‌کند.
۴. پورت انتخابی را در فایروال سمت server باز کن.
۵. از **Manage tunnels ← Test** برای تست لینک استفاده کن.

## نکته‌ها

- باینری‌ها موقع نصب از ریلیز رسمی هر پروژه دانلود می‌شوند و داخل این ریپو نیستند؛ لایسنس خودشان اعمال می‌شود.
- تونل TUN فعلاً فقط روی سرور **x86_64** کار می‌کند.
- **توکن** مثل رمز عبور است و کلیدهای WireGuard از آن ساخته می‌شود؛ از توکن خودکار (۳۲ کاراکتر) استفاده کن.
- `tun-icmp` تا وقتی تونل روشن است جواب پینگ معمولی سرور را قطع می‌کند.
- اسکریپت IP مبدأ را جعل نمی‌کند.

## لایسنس

MIT برای این اسکریپت.
