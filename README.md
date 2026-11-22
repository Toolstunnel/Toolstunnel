# Toolstunnel

**Interactive reverse-tunnel manager for Linux servers — one menu, three tunnel families.**

[English](#english) · [فارسی](#فارسی)

---

# English

Toolstunnel is a Bash script. It installs and manages open-source tunnel programs for you and creates a `systemd` service for every tunnel (auto-start, auto-restart). It asks a few simple questions, so no networking knowledge is needed.

```
bash <(curl -fsSL https://raw.githubusercontent.com/Toolstunnel/Toolstunnel/main/install.sh)
```

Run it as **root** on **both** servers. Next time just run `toolstunnel`.

## What it can create

| Menu item | Types | Built on |
| --- | --- | --- |
| Stream tunnel | `tcpmux` `tcp` `ws` `wss` `wsmux` `wssmux` | [Backhaul](https://github.com/Musixal/Backhaul) |
| Stream tunnel | `kcp` · `quic` (UDP) | [frp](https://github.com/fatedier/frp) |
| Stream tunnel | `quantum` (KCP inside fake-TCP, no UDP on the wire) | frp + [udp2raw](https://github.com/wangyu-/udp2raw) |
| TUN tunnel | `tun-tcp` (fake-TCP) · `tun-udp` · `tun-icmp` | WireGuard + [udp2raw](https://github.com/wangyu-/udp2raw) |
| TUN tunnel | `tun-ip` (GRE or IPIP carrier) | WireGuard inside a kernel IP tunnel |
| Kernel tunnel | `gre` · `gretap` · `ipip` · `sit` · `l2tp` | Linux kernel (`ip link`, `ip l2tp`) |

TUN and kernel tunnels give both servers a **private network** (default `10.10.10.1/24` on the server ↔ `10.10.10.2/24` on the client; you can change both). Traffic is encrypted in TUN tunnels (WireGuard); kernel tunnels are **not** encrypted — encrypt inside the service (TLS) if you need it.

| Type | Layer | Good for |
| --- | --- | --- |
| `gre` | 3 | Highest throughput |
| `gretap` | 2 | Ethernet frames / bridging |
| `ipip` | 3 | Lowest overhead (IPv4 only) |
| `sit` | 3 | IPv6 over IPv4 (6in4) |
| `l2tp` | 2 | L2TPv3 over UDP (NAT friendly) or raw IP |
| `tun-tcp` | 3 | Looks like TCP on the wire |
| `tun-udp` | 3 | Plain UDP, fast |
| `tun-icmp` | 3 | When only ping is allowed |
| `tun-ip` | 3 | Encrypted, carried as raw IP packets (protocol 47 or 4) |

## How to use

1. Install on both servers.
2. On the listening server (usually Iran) choose **server**. On the other (usually abroad) choose **client**.
3. Use the same type, port and **token** on both sides. The script prints the values to copy, including the two TUN addresses (swapped for the other side).
4. Open the chosen port in the firewall of the server side.
5. Open **Manage tunnels → Health check** to see loss, latency and jitter.

## What it asks

| Question | Applies to | Notes |
| --- | --- | --- |
| Server or client | all | Server listens, client dials in |
| Name | all | Up to 12 characters |
| Type | all | See the table above |
| Real IPs of both servers | kernel | This server's IP is detected automatically |
| Server IP and port, token | stream, TUN | Token must match on both sides |
| **TUN Local / Remote Address** (CIDR) | TUN, kernel | Defaults `10.10.10.1/24` ↔ `10.10.10.2/24` (reversed on the client). For another tunnel on the same server the next free network (`10.10.11.x`, …) is suggested |
| **Advanced options** (y/N) | stream, TUN, kernel | Parallel links · MTU · **speed limit (Mbps)** · TTL · GRE key · L2TP encapsulation, port and id |
| Ports to forward | server side | See below |
| Deliver them to | server side | Address on the other side, default = its tunnel address |

## Network tuning (optional)

Main menu → **Network tuning** applies a kernel profile for the whole server: `balanced` (BBR + fq), `fast` (big buffers) or `latency` (small buffers + fq_codel). The old values are saved first, and **reset** restores them.

## Forwarding ports

Type a comma-separated list:

| You type | Meaning |
| --- | --- |
| `2052` | TCP port 2052 → same port on the other side |
| `2052/udp` | UDP only |
| `2052/both` | TCP and UDP |
| `8443=443` | Listen on 8443, deliver to 443 |
| `8443=443/udp` | Same, UDP |
| `1000-2000` | TUN / kernel only: a whole range to the same ports |
| `1000-2000=443` | TUN / kernel only: a whole range delivered to one port |

For stream tunnels (Backhaul) use its own syntax, for example `2052,8443=443,1000-2000`, `443-600:5201` (a range delivered to one port) or `443=1.1.1.1:5201` (a target IP). On a `tcp` tunnel the server can also ask to carry UDP on the same ports (`accept_udp`).

**`kcp`, `quic` and `quantum` work differently:** the ports are asked on the **client** side (the foreign server). They are opened on the server and land on the client machine (`127.0.0.1` by default, or the address you type). Use the same list syntax as above, including `/udp` and `/both`. Edit them later on the client with **Edit ports**.

Change the list later with **Manage tunnels → your tunnel → Edit ports** (no need to recreate the tunnel).

The service on the other side must listen on the delivery address (or on `0.0.0.0`).

## Look and feel

The main menu shows a banner, your server IP, location and datacenter, which cores are installed and how many tunnels are active. The IP details come from one request to `ipinfo.io` per run; set `TT_NO_IPINFO=1` to turn it off.

## Notes

- Binaries are downloaded at install time from the official releases of each project; they are not stored in this repository. Their own licenses apply.
- `tun-tcp`, `tun-udp` and `tun-icmp` (udp2raw) currently need an **x86_64** server. All other types also work on ARM64.
- The **token** is a password: WireGuard keys are derived from it. Use the generated one (32 random characters).
- `tun-icmp` makes the server ignore normal pings while the tunnel runs.
- `tun-ip` needs both servers to have a real public IP (no NAT) and your provider to allow GRE (47) or IPIP (4). It also works on ARM64.
- The **speed limit** caps what this server sends into the tunnel; set it on both sides for a two-way cap.
- GRE, GRETAP, IPIP, SIT and L2TP need your provider to allow those protocols between the two servers.
- `quantum` runs frp's KCP on loopback only and carries it between the servers inside fake-TCP packets (udp2raw), encrypted with a key derived from the token. Nothing UDP crosses the network. It needs an **x86_64** server, the chosen **TCP** port open in the firewall, and no real service listening on that port (443 is a good choice if it is free).
- **TLS fragment** (Advanced options on a `wss`/`wssmux` **client**): a small local Python proxy sends the first TLS packet in pieces of 20-80 bytes with a few ms between them, which helps against DPI that only reads the first packet. It does not add encryption or authentication. If you connect by IP address there is no SNI to hide, so the benefit is against pattern matching only. Needs `python3` (installed automatically if missing).
- `kcp` and `quic` need UDP to pass between the two servers. `quic` collapses on lossy paths; use `kcp` or `tcpmux` there.
- **Parallel links** (Advanced options on Backhaul tunnels) opens several TCP links at once, which helps when a network throttles each connection. It is the closest thing to a bonded-TCP mode here.
- The script does not forge source IP addresses.

## Troubleshooting

| Problem | Try |
| --- | --- |
| Health check shows no replies | Is the other side created? Same type, port, token, network? Is the port open in the firewall? |
| Packet loss or high jitter | Lower the MTU (Advanced options), try another type or port |
| Kernel tunnel will not come up | `journalctl -u toolstunnel-NAME -n 50`; check that your provider allows the protocol |
| Forwarded port does not answer | The service on the other side must listen on the delivery address or `0.0.0.0` |

## Not included

`sctp`, kernel Multipath TCP (`mptcp`), `anytls`, `probe_decoy` (it needs a custom tunnel core), `http`/`https` mimicry, source-IP spoofing and other names found in closed-source tools. They need a custom tunnel core or kernel support that third-party programs do not provide.

## License

MIT for this script. Backhaul, udp2raw and WireGuard have their own licenses.

---

# فارسی

Toolstunnel یک اسکریپت Bash است که برنامه‌های متن‌باز تونل را نصب و مدیریت می‌کند و برای هر تونل یک سرویس `systemd` می‌سازد (اجرای خودکار بعد از ریبوت و وصل‌شدن مجدد). چند سؤال ساده می‌پرسد و نیازی به دانش شبکه نیست.

## نصب

```
bash <(curl -fsSL https://raw.githubusercontent.com/Toolstunnel/Toolstunnel/main/install.sh)
```

روی **هر دو** سرور و با کاربر **root** اجرا کن. دفعهٔ بعد فقط بنویس: `toolstunnel`

## چه تونل‌هایی می‌سازد

| بخش منو | نوع‌ها | بر پایهٔ |
| --- | --- | --- |
| تونل جریانی (Stream) | `tcpmux` `tcp` `ws` `wss` `wsmux` `wssmux` | Backhaul |
| تونل جریانی (Stream) | `kcp` · `quic` (روی UDP) | frp |
| تونل جریانی (Stream) | `quantum` (‏KCP داخل TCP جعلی، بدون UDP روی سیم) | frp + udp2raw |
| تونل TUN | `tun-tcp` (فیک‌تی‌سی‌پی) · `tun-udp` · `tun-icmp` | WireGuard + udp2raw |
| تونل TUN | `tun-ip` (حامل GRE یا IPIP) | WireGuard داخل تونل IP کرنل |
| تونل کرنلی | `gre` · `gretap` · `ipip` · `sit` · `l2tp` | خود کرنل لینوکس |

تونل‌های TUN و کرنلی یک **شبکهٔ خصوصی** بین دو سرور می‌سازند (پیش‌فرض `10.10.10.1/24` روی server ↔ `10.10.10.2/24` روی client؛ هر دو قابل تغییرند). تونل TUN رمزنگاری دارد (WireGuard)؛ تونل‌های کرنلی **رمزنگاری ندارند**، اگر لازم است داخل خود سرویس (TLS) انجام بده.

| نوع | لایه | مناسب برای |
| --- | --- | --- |
| `gre` | ۳ | بیشترین سرعت |
| `gretap` | ۲ | فریم اترنت / bridge |
| `ipip` | ۳ | کمترین سربار (فقط IPv4) |
| `sit` | ۳ | IPv6 روی IPv4 |
| `l2tp` | ۲ | L2TPv3 روی UDP (سازگار با NAT) یا IP خام |
| `tun-tcp` | ۳ | روی شبکه شبیه TCP دیده می‌شود |
| `tun-udp` | ۳ | UDP ساده و سریع |
| `tun-icmp` | ۳ | وقتی فقط پینگ باز است |
| `tun-ip` | ۳ | رمزنگاری‌شده، روی بسته‌های IP خام (پروتکل ۴۷ یا ۴) |

## طرز استفاده

۱. روی هر دو سرور نصب کن.
۲. روی سروری که گوش می‌دهد (معمولاً ایران) گزینهٔ **server** و روی سرور دیگر (معمولاً خارج) گزینهٔ **client** را بزن.
۳. نوع، پورت، شبکه و **توکن** باید روی هر دو یکی باشد. اسکریپت مقادیر را در پایان چاپ می‌کند.
۴. پورت انتخابی را در فایروال سمت server باز کن.
۵. از **Manage tunnels ← Health check** برای دیدن loss، تأخیر و jitter استفاده کن.

## چه سؤال‌هایی می‌پرسد

- **server یا client**
- **اسم** تونل (حداکثر ۱۲ کاراکتر)
- **نوع** تونل
- **IP واقعی هر دو سرور** (فقط تونل کرنلی؛ IP همین سرور خودکار پیدا می‌شود)
- **IP و پورت سرور و توکن** (تونل Stream و TUN)
- **TUN Local / Remote Address** (با CIDR؛ پیش‌فرض `10.10.10.1/24` ↔ `10.10.10.2/24` و روی client برعکس). برای تونل دوم روی همان سرور، شبکهٔ آزاد بعدی (`10.10.11.x` و ...) پیشنهاد می‌شود
- **Advanced options** (پیش‌فرض نه): تعداد لینک موازی، MTU، **محدودیت سرعت (Mbps)**، TTL، کلید GRE، نوع و پورت و id در L2TP
- **پورت‌هایی که فوروارد شوند** (سمت server) و **آدرس مقصد** در سمت دیگر

## تیونینگ شبکه (اختیاری)

منوی اصلی ← **Network tuning** یک پروفایل کرنلی برای کل سرور اعمال می‌کند: `balanced` (‏BBR + fq)، `fast` (بافر بزرگ) یا `latency` (بافر کوچک + fq_codel). مقدارهای قبلی اول ذخیره می‌شوند و گزینهٔ **reset** برشان می‌گرداند.

## فوروارد پورت

لیست را با کاما جدا کن:

| می‌نویسی | معنی |
| --- | --- |
| `2052` | پورت TCP ‏2052 به همان پورت در سمت دیگر |
| `2052/udp` | فقط UDP |
| `2052/both` | هر دو TCP و UDP |
| `8443=443` | روی 8443 گوش بده، به 443 برسان |
| `8443=443/udp` | همان، برای UDP |
| `1000-2000` | فقط TUN و کرنلی: کل بازه به همان پورت‌ها |
| `1000-2000=443` | فقط TUN و کرنلی: کل بازه به یک پورت |

برای تونل Stream از قالب خود Backhaul استفاده کن، مثلاً `2052,8443=443,1000-2000` یا `443-600:5201` (بازه به یک پورت) یا `443=1.1.1.1:5201` (آی‌پی مقصد). روی تونل `tcp` سرور می‌تواند بپرسد UDP هم روی همان پورت‌ها رد شود (`accept_udp`).

**در `kcp` و `quic` و `quantum` فرق دارد:** پورت‌ها سمت **client** (سرور خارج) پرسیده می‌شود. روی server باز می‌شوند و به سرور client می‌رسند (پیش‌فرض `127.0.0.1` یا آدرسی که بنویسی). قالب لیست همان است و `/udp` و `/both` هم کار می‌کند. بعداً با **Edit ports** روی client عوضش کن.

لیست را بعداً بدون ساخت دوبارهٔ تونل می‌شود عوض کرد: **Manage tunnels ← تونل ← Edit ports**.

سرویس سمت دیگر باید روی آدرس مقصد (یا `0.0.0.0`) گوش بدهد.

## ظاهر منو

منوی اصلی یک بنر، IP و موقعیت و دیتاسنتر سرور، هسته‌های نصب‌شده و تعداد تونل‌های فعال را نشان می‌دهد. اطلاعات IP با یک درخواست به `ipinfo.io` در هر بار اجرا گرفته می‌شود؛ با `TT_NO_IPINFO=1` خاموشش کن.

## نکته‌ها

- باینری‌ها موقع نصب از ریلیز رسمی هر پروژه دانلود می‌شوند و داخل این ریپو نیستند؛ لایسنس خودشان اعمال می‌شود.
- `tun-tcp` و `tun-udp` و `tun-icmp` (‏udp2raw) فعلاً فقط روی سرور **x86_64** کار می‌کنند. بقیهٔ نوع‌ها روی ARM64 هم کار می‌کنند.
- **توکن** مثل رمز عبور است و کلیدهای WireGuard از آن ساخته می‌شود؛ از توکن خودکار (۳۲ کاراکتر) استفاده کن.
- `tun-icmp` تا وقتی تونل روشن است جواب پینگ معمولی سرور را قطع می‌کند.
- `tun-ip` به IP عمومی واقعی روی هر دو سرور (بدون NAT) و اجازهٔ GRE (۴۷) یا IPIP (۴) از طرف دیتاسنتر نیاز دارد. روی ARM64 هم کار می‌کند.
- **محدودیت سرعت** فقط چیزی را که این سرور وارد تونل می‌کند محدود می‌کند؛ برای محدودیت دوطرفه روی هر دو سمت بگذار.
- برای GRE، GRETAP، IPIP، SIT و L2TP باید دیتاسنتر این پروتکل‌ها را بین دو سرور اجازه بدهد.
- `quantum` فقط روی لوپ‌بک KCP (frp) اجرا می‌کند و بین دو سرور آن را داخل بسته‌های TCP جعلی (udp2raw) و رمزنگاری‌شده با کلید مشتق از توکن می‌فرستد؛ هیچ UDP روی شبکه رد نمی‌شود. به سرور **x86_64**، باز بودن پورت **TCP** انتخابی در فایروال، و نبودن سرویس واقعی روی همان پورت نیاز دارد (اگر آزاد است 443 انتخاب خوبی است).
- **TLS fragment** (در Advanced options تونل `wss`/`wssmux` سمت **client**): یک پروکسی کوچک Python محلی اولین بستهٔ TLS را در تکه‌های ۲۰ تا ۸۰ بایتی با چند میلی‌ثانیه فاصله می‌فرستد و در برابر DPI که فقط بستهٔ اول را می‌خواند کمک می‌کند. رمزنگاری یا احراز هویت اضافه نمی‌کند. اگر با IP وصل شوی SNI‌ای برای پنهان‌کردن نیست و فقط در برابر الگوشناسی کمک می‌کند. به `python3` نیاز دارد (در صورت نبودن خودکار نصب می‌شود).
- `kcp` و `quic` به عبور UDP بین دو سرور نیاز دارند. `quic` روی مسیر پر از loss ضعیف می‌شود؛ آنجا `kcp` یا `tcpmux` بزن.
- **لینک موازی** (Advanced options در تونل‌های Backhaul) چند اتصال TCP هم‌زمان باز می‌کند و وقتی شبکه هر اتصال را جداگانه کند می‌کند کمک می‌کند. نزدیک‌ترین چیز به حالت bonded-TCP همین است.
- اسکریپت IP مبدأ را جعل نمی‌کند.

## رفع مشکل

| مشکل | راه‌حل |
| --- | --- |
| Health check جواب نمی‌گیرد | سمت دیگر ساخته شده؟ نوع، پورت، توکن و شبکه یکی است؟ پورت در فایروال باز است؟ |
| loss یا jitter بالا | MTU را کمتر کن (Advanced options)، نوع یا پورت دیگری امتحان کن |
| تونل کرنلی بالا نمی‌آید | `journalctl -u toolstunnel-NAME -n 50` را ببین و اجازهٔ پروتکل را از دیتاسنتر بپرس |
| پورت فورواردشده جواب نمی‌دهد | سرویس سمت دیگر باید روی آدرس مقصد یا `0.0.0.0` گوش بدهد |

## لایسنس

MIT برای این اسکریپت.
