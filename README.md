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
| TUN tunnel | `tun-tcp` (fake-TCP) · `tun-udp` · `tun-icmp` | WireGuard + [udp2raw](https://github.com/wangyu-/udp2raw) |
| Kernel tunnel | `gre` · `gretap` · `ipip` · `sit` · `l2tp` | Linux kernel (`ip link`, `ip l2tp`) |

TUN and kernel tunnels give both servers a **private network** (default `10.88.0.1` ↔ `10.88.0.2`, or `10.99.0.1` ↔ `10.99.0.2`). Traffic is encrypted in TUN tunnels (WireGuard); kernel tunnels are **not** encrypted — encrypt inside the service (TLS) if you need it.

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

## How to use

1. Install on both servers.
2. On the listening server (usually Iran) choose **server**. On the other (usually abroad) choose **client**.
3. Use the same type, port, network and **token** on both sides. The script prints the values to copy.
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
| Private tunnel network | TUN, kernel | First 3 octets, server = `.1`, client = `.2` |
| **Advanced options** (y/N) | stream, TUN, kernel | Parallel links · MTU · TTL · GRE key · L2TP encapsulation, port and id |
| Ports to forward | server side | See below |
| Deliver them to | server side | Address on the other side, default = its tunnel address |

## Forwarding ports

Type a comma-separated list:

| You type | Meaning |
| --- | --- |
| `2052` | TCP port 2052 → same port on the other side |
| `2052/udp` | UDP only |
| `2052/both` | TCP and UDP |
| `8443=443` | Listen on 8443, deliver to 443 |
| `8443=443/udp` | Same, UDP |

For stream tunnels (Backhaul) use its own syntax, for example `2052,8443=443,1000-2000`.

**`kcp` and `quic` work differently:** the ports are asked on the **client** side (the foreign server). They are opened on the server and land on the client machine (`127.0.0.1` by default, or the address you type). Use the same list syntax as above, including `/udp` and `/both`. Edit them later on the client with **Edit ports**.

Change the list later with **Manage tunnels → your tunnel → Edit ports** (no need to recreate the tunnel).

The service on the other side must listen on the delivery address (or on `0.0.0.0`).

## Notes

- Binaries are downloaded at install time from the official releases of each project; they are not stored in this repository. Their own licenses apply.
- TUN tunnels (udp2raw) currently need an **x86_64** server. Stream and kernel tunnels also work on ARM64.
- The **token** is a password: WireGuard keys are derived from it. Use the generated one (32 random characters).
- `tun-icmp` makes the server ignore normal pings while the tunnel runs.
- GRE, GRETAP, IPIP, SIT and L2TP need your provider to allow those protocols between the two servers.
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

`sctp`, kernel Multipath TCP (`mptcp`), `anytls`, `http`/`https` mimicry, source-IP spoofing and other names found in closed-source tools. They need a custom tunnel core or kernel support that third-party programs do not provide.

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
| تونل TUN | `tun-tcp` (فیک‌تی‌سی‌پی) · `tun-udp` · `tun-icmp` | WireGuard + udp2raw |
| تونل کرنلی | `gre` · `gretap` · `ipip` · `sit` · `l2tp` | خود کرنل لینوکس |

تونل‌های TUN و کرنلی یک **شبکهٔ خصوصی** بین دو سرور می‌سازند (پیش‌فرض `10.88.0.1` ↔ `10.88.0.2` یا `10.99.0.1` ↔ `10.99.0.2`). تونل TUN رمزنگاری دارد (WireGuard)؛ تونل‌های کرنلی **رمزنگاری ندارند**، اگر لازم است داخل خود سرویس (TLS) انجام بده.

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
- **شبکهٔ خصوصی تونل** (سه عدد اول؛ server = `.1` و client = `.2`)
- **Advanced options** (پیش‌فرض نه): تعداد لینک موازی، MTU، TTL، کلید GRE، نوع و پورت و id در L2TP
- **پورت‌هایی که فوروارد شوند** (سمت server) و **آدرس مقصد** در سمت دیگر

## فوروارد پورت

لیست را با کاما جدا کن:

| می‌نویسی | معنی |
| --- | --- |
| `2052` | پورت TCP ‏2052 به همان پورت در سمت دیگر |
| `2052/udp` | فقط UDP |
| `2052/both` | هر دو TCP و UDP |
| `8443=443` | روی 8443 گوش بده، به 443 برسان |
| `8443=443/udp` | همان، برای UDP |

برای تونل Stream از قالب خود Backhaul استفاده کن، مثلاً `2052,8443=443,1000-2000`.

**در `kcp` و `quic` فرق دارد:** پورت‌ها سمت **client** (سرور خارج) پرسیده می‌شود. روی server باز می‌شوند و به سرور client می‌رسند (پیش‌فرض `127.0.0.1` یا آدرسی که بنویسی). قالب لیست همان است و `/udp` و `/both` هم کار می‌کند. بعداً با **Edit ports** روی client عوضش کن.

لیست را بعداً بدون ساخت دوبارهٔ تونل می‌شود عوض کرد: **Manage tunnels ← تونل ← Edit ports**.

سرویس سمت دیگر باید روی آدرس مقصد (یا `0.0.0.0`) گوش بدهد.

## نکته‌ها

- باینری‌ها موقع نصب از ریلیز رسمی هر پروژه دانلود می‌شوند و داخل این ریپو نیستند؛ لایسنس خودشان اعمال می‌شود.
- تونل TUN فعلاً فقط روی سرور **x86_64** کار می‌کند.
- **توکن** مثل رمز عبور است و کلیدهای WireGuard از آن ساخته می‌شود؛ از توکن خودکار (۳۲ کاراکتر) استفاده کن.
- `tun-icmp` تا وقتی تونل روشن است جواب پینگ معمولی سرور را قطع می‌کند.
- برای GRE، GRETAP، IPIP، SIT و L2TP باید دیتاسنتر این پروتکل‌ها را بین دو سرور اجازه بدهد.
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
