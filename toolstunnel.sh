#!/usr/bin/env bash
# =====================================================================
#  Toolstunnel - interactive manager for reverse tunnels
#
#   1) Stream tunnels : Backhaul  (tcp, tcpmux, ws, wss, wsmux, wssmux)
#   2) TUN tunnels    : WireGuard + udp2raw  (tun-tcp, tun-udp, tun-icmp)
#   3) Kernel tunnels : GRE / IPIP / SIT
#
#  Third-party programs (Backhaul, udp2raw, WireGuard) are downloaded or
#  installed from their official sources. They are NOT bundled here.
# =====================================================================
set -u

APP="toolstunnel"
VERSION="0.1.0"
BASE="${TT_BASE:-/opt/toolstunnel}"
BIN="$BASE/bin"
CONF="${TT_CONF:-/etc/toolstunnel}"
TDIR="$CONF/tunnels"
UNIT_DIR="${TT_UNIT_DIR:-/etc/systemd/system}"
WG_DIR="${TT_WG_DIR:-/etc/wireguard}"

# >>> Change Toolstunnel to your GitHub username <<<
REPO_RAW="https://raw.githubusercontent.com/Toolstunnel/Toolstunnel/main"

BACKHAUL_URL="https://github.com/Musixal/Backhaul/releases/latest/download"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz"

if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

info() { printf '%s\n' "${C_B}[*]${C_0} $*"; }
ok()   { printf '%s\n' "${C_G}[+]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[!]${C_0} $*"; }
err()  { printf '%s\n' "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."; }
pause()     { read -r -p "Press Enter to continue..." _ || true; }

# ---------------------------------------------------------------------
#  Input helpers
# ---------------------------------------------------------------------
ask() { # ask VAR "Prompt" [default]
  local __v="$1" __p="$2" __d="${3:-}" __in=""
  if [[ -n "$__d" ]]; then
    IFS= read -r -p "$__p [$__d]: " __in || die "Input closed."
    __in="${__in:-$__d}"
  else
    IFS= read -r -p "$__p: " __in || die "Input closed."
  fi
  printf -v "$__v" '%s' "$__in"
}

ask_valid() { # ask_valid VAR "Prompt" "default" validator
  local __v="$1" __p="$2" __d="$3" __f="$4" __x=""
  while true; do
    ask "$__v" "$__p" "$__d"
    __x="${!__v}"
    if "$__f" "$__x"; then return 0; fi
    warn "Invalid value, try again."
  done
}

choose() { # choose VAR "Title" "option text" ...   -> VAR = chosen option text
  local __v="$1" __t="$2"; shift 2
  local opts=("$@") n=${#opts[@]} i pick=""
  echo; echo "$__t"
  for ((i = 0; i < n; i++)); do printf '  %d) %s\n' $((i + 1)) "${opts[i]}"; done
  while true; do
    IFS= read -r -p "Choose [1-$n]: " pick || die "Input closed."
    if [[ "$pick" =~ ^[0-9]+$ ]] && ((10#$pick >= 1 && 10#$pick <= n)); then
      printf -v "$__v" '%s' "${opts[10#$pick - 1]}"
      return 0
    fi
    warn "Invalid choice."
  done
}

# ---------------------------------------------------------------------
#  Validators
# ---------------------------------------------------------------------
valid_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

valid_ipv4() {
  local ip="${1:-}" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for o in $ip; do ((10#$o <= 255)) || return 1; done
  return 0
}

valid_host()   { [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
valid_name()   { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]{0,11}$ ]]; }
valid_token()  { [[ "${1:-}" =~ ^[A-Za-z0-9._~-]{16,}$ ]]; }
valid_prefix() { # a.b.c  (first three octets)
  local p="${1:-}" o
  [[ "$p" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){2}$ ]] || return 1
  local IFS=.
  for o in $p; do ((10#$o <= 255)) || return 1; done
  return 0
}
valid_bh_ports()  { [[ "${1:-}" =~ ^[0-9]+(-[0-9]+)?(=[0-9]+)?(,[0-9]+(-[0-9]+)?(=[0-9]+)?)*$ ]]; }
valid_fwd_ports() { [[ -z "${1:-}" || "$1" =~ ^[0-9]+(=[0-9]+)?(,[0-9]+(=[0-9]+)?)*$ ]]; }

gen_token() { tr -dc 'a-f0-9' </dev/urandom | head -c 32; }

tt_key() { # deterministic 32-byte key (base64) from a string
  printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 -A
}
tt_hex() { # deterministic hex string from a string
  printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
}

# ---------------------------------------------------------------------
#  System / downloads
# ---------------------------------------------------------------------
detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)  ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *) err "Unsupported CPU: $(uname -m)"; return 1 ;;
  esac
}

pkg_install() { # pkg_install <apt names> -- <rpm names>
  local apt_pk=() rpm_pk=() side=apt a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then side=rpm; continue; fi
    if [[ $side == apt ]]; then apt_pk+=("$a"); else rpm_pk+=("$a"); fi
  done
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_pk[@]}" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "${rpm_pk[@]}" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "${rpm_pk[@]}" >/dev/null 2>&1
  else
    err "No supported package manager (apt/dnf/yum) found."
    return 1
  fi
}

ensure_base() {
  local c missing=0
  for c in curl tar openssl iptables ip systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  if ((missing)); then
    info "Installing required packages..."
    pkg_install curl tar openssl iptables iproute2 -- curl tar openssl iptables iproute || true
  fi
  for c in curl tar openssl iptables ip systemctl; do
    command -v "$c" >/dev/null 2>&1 || { err "Missing command: $c"; return 1; }
  done
  mkdir -p "$BIN" "$TDIR"
  chmod 700 "$CONF" 2>/dev/null || true
}

ensure_wireguard() {
  command -v wg-quick >/dev/null 2>&1 && command -v wg >/dev/null 2>&1 && return 0
  info "Installing WireGuard tools..."
  pkg_install wireguard-tools -- wireguard-tools || true
  command -v wg-quick >/dev/null 2>&1 || { err "Could not install wireguard-tools."; return 1; }
}

install_backhaul() {
  [[ -x "$BIN/backhaul" ]] && return 0
  detect_arch || return 1
  local tmp f; tmp="$(mktemp -d)"
  info "Downloading Backhaul ($ARCH)..."
  if ! curl -fsSL --retry 3 -o "$tmp/bh.tgz" "$BACKHAUL_URL/backhaul_linux_${ARCH}.tar.gz"; then
    rm -rf "$tmp"
    err "Download failed. Check that this server can reach github.com,"
    err "or place the 'backhaul' binary manually at $BIN/backhaul and retry."
    return 1
  fi
  tar -xzf "$tmp/bh.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; err "Could not extract Backhaul."; return 1; }
  f="$(find "$tmp" -type f -name backhaul | head -n1)"
  [[ -n "$f" ]] || { rm -rf "$tmp"; err "backhaul binary not found in the archive."; return 1; }
  install -m 0755 "$f" "$BIN/backhaul"
  rm -rf "$tmp"
  ok "Backhaul installed."
}

install_udp2raw() {
  [[ -x "$BIN/udp2raw" ]] && return 0
  detect_arch || return 1
  if [[ "$ARCH" != "amd64" ]]; then
    err "TUN tunnels (udp2raw) are only supported on x86_64 servers in this version."
    return 1
  fi
  local tmp; tmp="$(mktemp -d)"
  info "Downloading udp2raw..."
  if ! curl -fsSL --retry 3 -o "$tmp/u2r.tgz" "$UDP2RAW_URL"; then
    rm -rf "$tmp"
    err "Download failed. Check that this server can reach github.com,"
    err "or place the 'udp2raw' binary manually at $BIN/udp2raw and retry."
    return 1
  fi
  tar -xzf "$tmp/u2r.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; err "Could not extract udp2raw."; return 1; }
  if [[ ! -f "$tmp/udp2raw_amd64" ]]; then
    rm -rf "$tmp"; err "udp2raw_amd64 not found in the archive."; return 1
  fi
  install -m 0755 "$tmp/udp2raw_amd64" "$BIN/udp2raw"
  rm -rf "$tmp"
  ok "udp2raw installed."
}

# ---------------------------------------------------------------------
#  Tunnel bookkeeping
# ---------------------------------------------------------------------
save_meta() { # save_meta name KEY=VAL ...
  local name="$1" kv; shift
  mkdir -p "$TDIR"
  : >"$TDIR/$name.meta"
  for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >>"$TDIR/$name.meta"; done
  chmod 600 "$TDIR/$name.meta"
}

load_meta() { # load_meta name
  unset KIND ROLE MODE PORT HOST TOKEN PEER LOCALIP IFACE
  # shellcheck disable=SC1090
  source "$TDIR/$1.meta"
}

tunnel_exists() { [[ -f "$TDIR/$1.meta" ]]; }

ask_name() {
  while true; do
    ask_valid name "Tunnel name (a-z, 0-9, dash; max 12 chars)" "tun1" valid_name
    if tunnel_exists "$name"; then warn "A tunnel named '$name' already exists."; else break; fi
  done
}

write_unit() { # write_unit name "description"   (service body on stdin)
  local name="$1" desc="$2" body
  body="$(cat)"
  cat >"$UNIT_DIR/$APP-$name.service" <<EOF
[Unit]
Description=Toolstunnel - $desc
After=network-online.target
Wants=network-online.target

[Service]
$body

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$APP-$name.service" >/dev/null 2>&1
  systemctl restart "$APP-$name.service" >/dev/null 2>&1
}

gen_fw_script() { # gen_fw_script name peer_ip "ports csv"
  local name="$1" peer="$2" ports="$3" f="$TDIR/$1.fw" spec src dst proto
  {
    echo '#!/usr/bin/env bash'
    echo '# usage: fw script up|down'
    echo 'if [[ "${1:-}" == up ]]; then OP=-A; else OP=-D; fi'
    echo 'ipt_fwd() { if [[ "$OP" == -A ]]; then iptables -I FORWARD 1 "$@"; else iptables -D FORWARD "$@"; fi; }'
    echo '[[ "$OP" == -A ]] && sysctl -w net.ipv4.ip_forward=1 >/dev/null'
    local IFS=','
    for spec in $ports; do
      src="${spec%%=*}"; dst="${spec##*=}"
      for proto in tcp udp; do
        echo "iptables -t nat \$OP PREROUTING -p $proto --dport $src -j DNAT --to-destination $peer:$dst || true"
      done
    done
    echo "iptables -t nat \$OP POSTROUTING -d $peer -j MASQUERADE || true"
    echo "ipt_fwd -d $peer -j ACCEPT || true"
    echo "ipt_fwd -s $peer -j ACCEPT || true"
    echo "exit 0"
  } >"$f"
  chmod 700 "$f"
}

# ---------------------------------------------------------------------
#  1) Stream tunnels (Backhaul)
# ---------------------------------------------------------------------
ports_toml() { printf '[%s]' "$(printf '%s' "$1" | sed 's/[^,][^,]*/"&"/g; s/,/, /g')"; }

gen_cert() { # gen_cert name
  local d="$CONF/certs"
  mkdir -p "$d"
  if [[ ! -f "$d/$1.crt" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/$1.key" -out "$d/$1.crt" \
      -days 3650 -subj "/CN=localhost" >/dev/null 2>&1 || return 1
    [[ -f "$d/$1.key" && -f "$d/$1.crt" ]] || return 1
    chmod 600 "$d/$1.key"
  fi
}

# uses: name role transport port host token ports
gen_backhaul_conf() {
  local f="$TDIR/$name.toml" mux=0 tls=0
  [[ "$transport" == *mux ]] && mux=1
  [[ "$transport" == wss* ]] && tls=1
  {
    if [[ "$role" == server ]]; then
      echo "[server]"
      echo "bind_addr = \"0.0.0.0:$port\""
    else
      echo "[client]"
      echo "remote_addr = \"$host:$port\""
    fi
    echo "transport = \"$transport\""
    echo "token = \"$token\""
    echo "log_level = \"info\""
    echo "sniffer = false"
    echo "nodelay = true"
    echo "keepalive_period = 75"
    if [[ "$role" == server ]]; then
      echo "heartbeat = 40"
      echo "channel_size = 2048"
      echo "ports = $(ports_toml "$ports")"
    else
      echo "connection_pool = 8"
      echo "aggressive_pool = false"
      echo "retry_interval = 3"
      echo "dial_timeout = 10"
    fi
    if ((mux)); then
      echo "mux_con = 8"
      echo "mux_version = 1"
      echo "mux_framesize = 32768"
      echo "mux_recievebuffer = 4194304"
      echo "mux_streambuffer = 65536"
    fi
    if ((tls)) && [[ "$role" == server ]]; then
      echo "tls_cert = \"$CONF/certs/$name.crt\""
      echo "tls_key = \"$CONF/certs/$name.key\""
    fi
  } >"$f"
  chmod 600 "$f"
}

build_backhaul() {
  if [[ "$transport" == wss* && "$role" == server ]]; then
    gen_cert "$name" || { err "Could not create a TLS certificate."; return 1; }
  fi
  gen_backhaul_conf
  save_meta "$name" KIND=stream ROLE="$role" MODE="$transport" PORT="$port" HOST="${host:-}" TOKEN="$token"
  write_unit "$name" "stream tunnel $name ($transport, $role)" <<EOF
Type=simple
ExecStart=$BIN/backhaul -c $TDIR/$name.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
}

create_stream() {
  ensure_base || return 1
  install_backhaul || return 1
  local pick role name transport port host="" token ports=""
  choose pick "Which side is this server?" \
    "server - listens for the tunnel (usually the Iran side)" \
    "client - dials in to the server (usually the foreign side)"
  role="${pick%% *}"
  ask_name
  choose pick "Transport:" \
    "tcpmux  - multiplexed TCP (fast, recommended)" \
    "tcp     - plain TCP" \
    "ws      - WebSocket" \
    "wss     - WebSocket + TLS" \
    "wsmux   - multiplexed WebSocket" \
    "wssmux  - multiplexed WebSocket + TLS"
  transport="${pick%% *}"
  if [[ "$role" == server ]]; then
    ask_valid port "Tunnel port to listen on" "3080" valid_port
    ask_valid ports "Ports to open for users (e.g. 2052,8443=443,1000-2000)" "" valid_bh_ports
    ask_valid token "Token (Enter = auto-generate)" "$(gen_token)" valid_token
  else
    ask_valid host "IP or domain of the SERVER side" "" valid_host
    ask_valid port "Tunnel port of the server" "3080" valid_port
    ask_valid token "Token (must match the server)" "" valid_token
  fi
  build_backhaul || return 1
  sleep 2
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  echo "On the OTHER server create a '$([[ $role == server ]] && echo client || echo server)' tunnel with:"
  echo "  transport : $transport"
  echo "  port      : $port"
  echo "  token     : $token"
  [[ "$role" == server ]] && echo "  (the client needs this server's public IP; open port $port in the firewall)"
  return 0
}

# ---------------------------------------------------------------------
#  2) TUN tunnels (WireGuard + udp2raw)  ->  tun-tcp / tun-udp / tun-icmp
# ---------------------------------------------------------------------
# uses: name role mode rawport host token prefix wgport lport fwd
build_wg() {
  local iface="tt-$name" sp cp psk spub cpub mine peer rawkey
  sp="$(tt_key "srv:$token")"; cp="$(tt_key "cli:$token")"; psk="$(tt_key "psk:$token")"
  rawkey="$(tt_hex "raw:$token")"
  spub="$(printf '%s' "$sp" | wg pubkey)"; cpub="$(printf '%s' "$cp" | wg pubkey)"
  [[ -n "$spub" && -n "$cpub" ]] || { err "Key derivation failed."; return 1; }
  if [[ "$role" == server ]]; then mine="$prefix.1"; peer="$prefix.2"; else mine="$prefix.2"; peer="$prefix.1"; fi

  mkdir -p "$WG_DIR"
  (
    umask 077
    if [[ "$role" == server ]]; then
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $mine/30
ListenPort = $wgport
PrivateKey = $sp
MTU = 1200

[Peer]
PublicKey = $cpub
PresharedKey = $psk
AllowedIPs = $peer/32
EOF
    else
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $mine/30
PrivateKey = $cp
MTU = 1200

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = 127.0.0.1:$lport
AllowedIPs = $peer/32
PersistentKeepalive = 25
EOF
    fi
  )

  local wgq sc raw_args pre="" post="" fw_start="" fw_stop=""
  wgq="$(command -v wg-quick)"; sc="$(command -v sysctl || echo /sbin/sysctl)"
  if [[ "$role" == server ]]; then
    raw_args="-s -l 0.0.0.0:$rawport -r 127.0.0.1:$wgport"
  else
    raw_args="-c -l 127.0.0.1:$lport -r $host:$rawport"
  fi
  if [[ "$mode" == icmp ]]; then
    pre="ExecStartPre=$sc -w net.ipv4.icmp_echo_ignore_all=1"
    post="ExecStopPost=-$sc -w net.ipv4.icmp_echo_ignore_all=0"
  fi
  if [[ "$role" == server && -n "$fwd" ]]; then
    gen_fw_script "$name" "$peer" "$fwd"
    fw_start="ExecStartPost=-/bin/bash $TDIR/$name.fw up"
    fw_stop="ExecStopPost=-/bin/bash $TDIR/$name.fw down"
  fi

  save_meta "$name" KIND=tun ROLE="$role" MODE="$mode" PORT="$rawport" HOST="${host:-}" TOKEN="$token" PEER="$peer" IFACE="$iface"
  write_unit "$name" "TUN tunnel $name (tun-$mode, $role)" <<EOF
Type=simple
$pre
ExecStartPre=-$wgq down $iface
ExecStartPre=$wgq up $iface
ExecStart=$BIN/udp2raw $raw_args -k $rawkey --raw-mode $mode --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --keep-rule
$fw_start
ExecStopPost=-$wgq down $iface
$fw_stop
$post
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
}

create_tun() {
  ensure_base || return 1
  ensure_wireguard || return 1
  install_udp2raw || return 1
  local pick role name mode rawport host="" token prefix wgport lport fwd=""
  choose pick "Which side is this server?" \
    "server - listens for the tunnel (usually the Iran side)" \
    "client - dials in to the server (usually the foreign side)"
  role="${pick%% *}"
  ask_name
  choose pick "Tunnel type:" \
    "tun-tcp  - private network over fake-TCP packets" \
    "tun-udp  - private network over UDP packets" \
    "tun-icmp - private network over ICMP (ping) packets"
  case "${pick%% *}" in
    tun-tcp) mode="faketcp" ;;
    tun-udp) mode="udp" ;;
    *)       mode="icmp" ;;
  esac
  if [[ "$role" == server ]]; then
    ask_valid rawport "Port to listen on (ignored by ICMP, still required)" "443" valid_port
    ask_valid token "Token / password (min 16 chars, Enter = auto-generate)" "$(gen_token)" valid_token
  else
    ask_valid host "Public IP of the SERVER side" "" valid_ipv4
    ask_valid rawport "Port of the server" "443" valid_port
    ask_valid token "Token (must match the server)" "" valid_token
  fi
  ask_valid prefix "Private tunnel network (first 3 octets; server=.1 client=.2)" "10.88.0" valid_prefix
  wgport=$((20000 + RANDOM % 20000)); lport=$((40000 + RANDOM % 20000))
  if [[ "$role" == server ]]; then
    ask_valid fwd "Ports to forward through the tunnel (e.g. 2052,8443=443; Enter = none)" "" valid_fwd_ports
  fi
  build_wg || return 1
  sleep 3
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  echo "On the OTHER server create a '$([[ $role == server ]] && echo client || echo server)' TUN tunnel with:"
  echo "  type    : tun-$mode"
  echo "  port    : $rawport"
  echo "  token   : $token"
  echo "  network : $prefix"
  [[ "$role" == server ]] && echo "  (the client needs this server's public IP; open port $rawport in the firewall)"
  echo "Then test from the 'Manage tunnels' menu (Test)."
  [[ "$mode" == icmp ]] && warn "ICMP mode makes this server ignore normal pings while the tunnel runs."
  return 0
}

# ---------------------------------------------------------------------
#  3) Kernel tunnels (GRE / IPIP / SIT)
# ---------------------------------------------------------------------
default_local_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# uses: name role mode localip remote prefix idx fwd
build_kernel() {
  local iface="tt-$name" mod addr peer f="$TDIR/$name.sh"
  case "$mode" in gre) mod=ip_gre ;; ipip) mod=ipip ;; sit) mod=sit ;; esac
  if [[ "$mode" == sit ]]; then
    if [[ "$role" == server ]]; then addr="fd88:$idx::1/64"; peer="fd88:$idx::2"; else addr="fd88:$idx::2/64"; peer="fd88:$idx::1"; fi
  else
    if [[ "$role" == server ]]; then addr="$prefix.1/30"; peer="$prefix.2"; else addr="$prefix.2/30"; peer="$prefix.1"; fi
  fi
  if [[ "$role" == server && "$mode" != sit && -n "$fwd" ]]; then gen_fw_script "$name" "$peer" "$fwd"; fi

  {
    echo '#!/usr/bin/env bash'
    echo "IFACE=\"$iface\""
    echo "FW=\"$TDIR/$name.fw\""
    echo 'down() {'
    echo '  [[ -f "$FW" ]] && bash "$FW" down >/dev/null 2>&1'
    echo '  ip link set dev "$IFACE" down >/dev/null 2>&1'
    echo '  ip tunnel del "$IFACE" >/dev/null 2>&1'
    echo '  return 0'
    echo '}'
    echo 'up() {'
    echo '  down'
    echo "  modprobe $mod 2>/dev/null"
    echo "  ip tunnel add \"\$IFACE\" mode $mode local $localip remote $remote ttl 255 || exit 1"
    if [[ "$mode" == sit ]]; then
      echo "  ip -6 addr add $addr dev \"\$IFACE\""
    else
      echo "  ip addr add $addr dev \"\$IFACE\""
    fi
    echo '  ip link set dev "$IFACE" mtu 1400 up'
    echo '  [[ -f "$FW" ]] && bash "$FW" up'
    echo '  return 0'
    echo '}'
    echo 'case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 1 ;; esac'
  } >"$f"
  chmod 700 "$f"

  save_meta "$name" KIND=kernel ROLE="$role" MODE="$mode" HOST="$remote" LOCALIP="$localip" PEER="$peer" IFACE="$iface"
  write_unit "$name" "kernel tunnel $name ($mode, $role)" <<EOF
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $f up
ExecStop=/bin/bash $f down
EOF
}

create_kernel() {
  ensure_base || return 1
  local pick role name mode localip remote prefix="10.99.0" idx fwd=""
  choose pick "Which side is this server?" \
    "server - gets the .1 address (usually the Iran side)" \
    "client - gets the .2 address (usually the foreign side)"
  role="${pick%% *}"
  ask_name
  choose pick "Tunnel type:" \
    "gre  - GRE (highest throughput)" \
    "ipip - IP-in-IP (lowest overhead, IPv4 only)" \
    "sit  - 6in4 (IPv6 over IPv4)"
  mode="${pick%% *}"
  ask_valid localip "This server's IP" "$(default_local_ip)" valid_ipv4
  ask_valid remote "The OTHER server's public IP" "" valid_ipv4
  if [[ "$mode" == sit ]]; then
    idx=$((1 + RANDOM % 200)); prefix=""
    ask_valid idx "IPv6 tunnel id (1-250, same on both sides)" "$idx" valid_port
  else
    idx=0
    ask_valid prefix "Private tunnel network (first 3 octets)" "10.99.0" valid_prefix
    [[ "$role" == server ]] && ask_valid fwd "Ports to forward through the tunnel (Enter = none)" "" valid_fwd_ports
  fi
  build_kernel || return 1
  sleep 1
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  echo "On the OTHER server create the opposite side with the same type and network."
  warn "Your provider/firewall must allow the protocol ($mode) between both servers."
  return 0
}

# ---------------------------------------------------------------------
#  Manage
# ---------------------------------------------------------------------
list_tunnels() {
  TUNNELS=()
  local f
  shopt -s nullglob
  for f in "$TDIR"/*.meta; do TUNNELS+=("$(basename "$f" .meta)"); done
  shopt -u nullglob
}

status_of() { systemctl is-active "$APP-$1.service" 2>/dev/null || true; }

show_status_all() {
  list_tunnels
  if ((${#TUNNELS[@]} == 0)); then warn "No tunnels yet."; return; fi
  printf '%-14s %-8s %-8s %-10s %s\n' NAME KIND ROLE TYPE STATUS
  local n
  for n in "${TUNNELS[@]}"; do
    load_meta "$n"
    printf '%-14s %-8s %-8s %-10s %s\n' "$n" "$KIND" "$ROLE" "$MODE" "$(status_of "$n")"
  done
}

delete_tunnel() {
  local n="$1" iface
  load_meta "$n"; iface="${IFACE:-}"
  systemctl disable --now "$APP-$n.service" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$APP-$n.service"
  systemctl daemon-reload
  if [[ "$KIND" == tun ]]; then
    wg-quick down "tt-$n" >/dev/null 2>&1
    rm -f "$WG_DIR/tt-$n.conf"
  fi
  [[ -f "$TDIR/$n.fw" ]] && bash "$TDIR/$n.fw" down >/dev/null 2>&1
  [[ "$KIND" == kernel && -n "$iface" ]] && ip tunnel del "$iface" >/dev/null 2>&1
  rm -f "$TDIR/$n".{meta,toml,fw,sh} "$CONF/certs/$n".{crt,key}
  ok "Tunnel '$n' removed."
}

test_tunnel() {
  local n="$1"
  load_meta "$n"
  if [[ "$KIND" == stream ]]; then
    echo "Service: $(status_of "$n")"
    if [[ "$ROLE" == server ]]; then ss -ltn 2>/dev/null | grep -E ":$PORT\b" || warn "Nothing is listening on $PORT."; fi
    journalctl -u "$APP-$n.service" -n 8 --no-pager 2>/dev/null
  else
    echo "Pinging the other side of the tunnel ($PEER)..."
    if [[ "$PEER" == *:* ]]; then ping -6 -c 4 -W 2 "$PEER"; else ping -c 4 -W 2 "$PEER"; fi
  fi
}

show_info() {
  local n="$1"
  load_meta "$n"
  echo "Name   : $n"
  echo "Kind   : $KIND"
  echo "Role   : $ROLE"
  echo "Type   : $MODE"
  [[ -n "${HOST:-}" ]] && echo "Remote : $HOST"
  [[ -n "${PORT:-}" ]] && echo "Port   : $PORT"
  [[ -n "${PEER:-}" ]] && echo "Peer   : $PEER (tunnel address)"
  [[ -n "${TOKEN:-}" ]] && echo "Token  : $TOKEN"
  echo "Status : $(status_of "$n")"
}

tunnel_menu() {
  local n="$1" pick
  while true; do
    echo; echo "--- Tunnel: $n ($(status_of "$n")) ---"
    echo " 1) Info        2) Restart     3) Stop"
    echo " 4) Logs        5) Live logs   6) Test"
    echo " 7) Delete      0) Back"
    IFS= read -r -p "Choose: " pick || die "Input closed."
    case "$pick" in
      1) show_info "$n" ;;
      2) systemctl restart "$APP-$n.service" && ok "Restarted." ;;
      3) systemctl stop "$APP-$n.service" && ok "Stopped." ;;
      4) journalctl -u "$APP-$n.service" -n 60 --no-pager ;;
      5) trap 'true' INT; journalctl -fu "$APP-$n.service"; trap - INT ;;
      6) test_tunnel "$n" ;;
      7) local yn; ask yn "Type 'yes' to delete '$n'" ""; if [[ "$yn" == yes ]]; then delete_tunnel "$n"; return; fi ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

manage_tunnels() {
  while true; do
    list_tunnels
    if ((${#TUNNELS[@]} == 0)); then warn "No tunnels yet."; return; fi
    echo; show_status_all
    local opts=() n pick
    for n in "${TUNNELS[@]}"; do opts+=("$n"); done
    opts+=("<- back")
    choose pick "Select a tunnel:" "${opts[@]}"
    [[ "$pick" == "<- back" ]] && return
    tunnel_menu "$pick"
  done
}

# ---------------------------------------------------------------------
#  Update / uninstall
# ---------------------------------------------------------------------
update_script() {
  local tmp; tmp="$(mktemp)"
  info "Downloading the latest script..."
  if ! curl -fsSL --retry 3 -o "$tmp" "$REPO_RAW/toolstunnel.sh"; then rm -f "$tmp"; err "Download failed."; return 1; fi
  if ! bash -n "$tmp"; then rm -f "$tmp"; err "Downloaded file is not valid. Update cancelled."; return 1; fi
  install -m 0755 "$tmp" "$BASE/toolstunnel.sh"; rm -f "$tmp"
  ok "Updated. Restart the script to use the new version."
}

uninstall_all() {
  local yn n
  ask yn "This removes ALL tunnels and Toolstunnel. Type 'yes' to continue" ""
  [[ "$yn" == yes ]] || { warn "Cancelled."; return; }
  list_tunnels
  for n in "${TUNNELS[@]}"; do delete_tunnel "$n"; done
  rm -rf "$BASE" "$CONF" "/usr/local/bin/$APP"
  ok "Toolstunnel removed. (WireGuard tools, if installed, were left in place.)"
  exit 0
}

# ---------------------------------------------------------------------
#  Main menu
# ---------------------------------------------------------------------
main_menu() {
  need_root
  mkdir -p "$TDIR"
  local pick
  while true; do
    echo
    echo "${C_B}=========================================${C_0}"
    echo "  Toolstunnel v$VERSION"
    echo "${C_B}=========================================${C_0}"
    echo " 1) Create stream tunnel   (tcpmux / tcp / ws / wss / wsmux / wssmux)"
    echo " 2) Create TUN tunnel      (tun-tcp / tun-udp / tun-icmp)"
    echo " 3) Create kernel tunnel   (GRE / IPIP / SIT)"
    echo " 4) Manage tunnels"
    echo " 5) Update script"
    echo " 6) Uninstall"
    echo " 0) Exit"
    IFS= read -r -p "Choose: " pick || exit 0
    case "$pick" in
      1) create_stream; pause ;;
      2) create_tun; pause ;;
      3) create_kernel; pause ;;
      4) manage_tunnels ;;
      5) update_script; pause ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -v | --version | version) echo "Toolstunnel $VERSION" ;;
    status) need_root; show_status_all ;;
    *) main_menu ;;
  esac
fi
