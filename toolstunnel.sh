#!/usr/bin/env bash
# =====================================================================
#  Toolstunnel - interactive manager for reverse tunnels
#
#   1) Stream tunnels : Backhaul  (tcp, tcpmux, ws, wss, wsmux, wssmux)
#                       frp       (kcp, quic)
#   2) TUN tunnels    : WireGuard + udp2raw / GRE  (tun-tcp, tun-udp, tun-icmp, tun-ip)
#   3) Kernel tunnels : GRE / GRETAP / IPIP / SIT / L2TPv3
#
#  Third-party programs (Backhaul, frp, udp2raw, WireGuard) are downloaded or
#  installed from their official sources. They are NOT bundled here.
# =====================================================================
set -u

APP="toolstunnel"
VERSION="0.5.0"
BASE="${TT_BASE:-/opt/toolstunnel}"
BIN="$BASE/bin"
CONF="${TT_CONF:-/etc/toolstunnel}"
TDIR="$CONF/tunnels"
UNIT_DIR="${TT_UNIT_DIR:-/etc/systemd/system}"
WG_DIR="${TT_WG_DIR:-/etc/wireguard}"

REPO_RAW="https://raw.githubusercontent.com/Toolstunnel/Toolstunnel/main"

BACKHAUL_URL="https://github.com/Musixal/Backhaul/releases/latest/download"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/latest/download/udp2raw_binaries.tar.gz"

if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
  C_BB=$'\e[1;94m'; C_O=$'\e[38;5;208m'; C_D=$'\e[90m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; C_BB=""; C_O=""; C_D=""
fi

info() { printf '%s\n' "${C_B}[*]${C_0} $*"; }
ok()   { printf '%s\n' "${C_G}[+]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[!]${C_0} $*"; }
err()  { printf '%s\n' "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }

section() { echo; echo "${C_BB}── $1 ──${C_0}"; }

need_root() { [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."; }
pause()     { read -r -p "Press Enter to continue..." _ || true; }

# ---------------------------------------------------------------------
#  Input helpers
# ---------------------------------------------------------------------
ask() { # ask VAR "Prompt" [default]
  local __v="$1" __p="$2" __d="${3:-}" __in=""
  if [[ -n "$__d" ]]; then
    printf '%s' "${C_B}[-]${C_0} $__p (default: $__d): "
  else
    printf '%s' "${C_B}[-]${C_0} $__p: "
  fi
  IFS= read -r __in || die "Input closed."
  __in="${__in:-$__d}"
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

ask_yes() { # ask_yes "Question" -> 0 if yes (default no)
  local __a=""
  ask __a "$1 [y/N]" ""
  [[ "$__a" =~ ^[Yy] ]]
}

choose() { # choose VAR "Title" "option text" ...   -> VAR = chosen option text
  local __v="$1" __t="$2"; shift 2
  local __opts=("$@") __n=$# __i __pick=""
  echo; echo "${C_B}$__t${C_0}"
  for ((__i = 0; __i < __n; __i++)); do printf '  %s%d.%s %s\n' "$C_G" $((__i + 1)) "$C_0" "${__opts[__i]}"; done
  while true; do
    printf '%s' "${C_B}[-]${C_0} Enter your choice [1-$__n]: "
    IFS= read -r __pick || die "Input closed."
    if [[ "$__pick" =~ ^[0-9]+$ ]] && ((10#$__pick >= 1 && 10#$__pick <= __n)); then
      printf -v "$__v" '%s' "${__opts[10#$__pick - 1]}"
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
valid_mtu()    { [[ "${1:-}" =~ ^[0-9]{3,4}$ ]] && ((10#$1 >= 576 && 10#$1 <= 9000)); }
valid_ttl()    { [[ "${1:-}" =~ ^[0-9]{1,3}$ ]] && ((10#$1 >= 1 && 10#$1 <= 255)); }
valid_limit()  { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]]; }
valid_links()  { [[ "${1:-}" =~ ^[0-9]{1,2}$ ]] && ((10#$1 >= 1 && 10#$1 <= 64)); }
valid_id()     { [[ "${1:-}" =~ ^[0-9]{1,9}$ ]] && ((10#$1 >= 1 && 10#$1 <= 999999999)); }
valid_key()    { [[ -z "${1:-}" ]] || { [[ "$1" =~ ^[0-9]{1,10}$ ]] && ((10#$1 <= 4294967295)); }; }

valid_cidr4() { # a.b.c.d/len  (len 8-30)
  local v="${1:-}"
  [[ "$v" == */* ]] || return 1
  valid_ipv4 "${v%%/*}" || return 1
  [[ "${v##*/}" =~ ^[0-9]{1,2}$ ]] && ((10#${v##*/} >= 8 && 10#${v##*/} <= 30))
}

valid_cidr6() { # xxxx::1/len  (len 48-126)
  local v="${1:-}"
  [[ "$v" == */* ]] || return 1
  [[ "${v%%/*}" =~ ^[0-9a-fA-F:]+$ && "${v%%/*}" == *:*:* ]] || return 1
  [[ "${v##*/}" =~ ^[0-9]{1,3}$ ]] && ((10#${v##*/} >= 48 && 10#${v##*/} <= 126))
}

ip2int() { local IFS=.; set -- $1; echo $(((10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4)); }

same_subnet() { # same_subnet a/len b/len -> two different hosts of one network
  local a="${1%/*}" b="${2%/*}" la="${1#*/}" lb="${2#*/}" mask
  [[ "$a" != "$b" && "$la" == "$lb" ]] || return 1
  local ia ib
  mask=$(((0xFFFFFFFF << (32 - 10#$la)) & 0xFFFFFFFF))
  ia="$(ip2int "$a")"; ib="$(ip2int "$b")"
  (((ia & mask) == (ib & mask)))
}

valid_bh_ports() { [[ "${1:-}" =~ ^[0-9]+(-[0-9]+)?(=[0-9]+)?(,[0-9]+(-[0-9]+)?(=[0-9]+)?)*$ ]]; }

# Forward list: 2052 | 2052/udp | 2052/both | 8443=443 | 8443=443/udp  (comma separated, empty = none)
valid_fwd_ports() {
  local s="${1:-}" spec base p
  local -a specs=() nums=()
  [[ -z "$s" ]] && return 0
  [[ "$s" =~ ^[0-9]+(=[0-9]+)?(/(tcp|udp|both))?(,[0-9]+(=[0-9]+)?(/(tcp|udp|both))?)*$ ]] || return 1
  IFS=',' read -ra specs <<<"$s"
  for spec in "${specs[@]}"; do
    base="${spec%%/*}"
    IFS='=' read -ra nums <<<"$base"
    for p in "${nums[@]}"; do valid_port "$p" || return 1; done
  done
  return 0
}
valid_fwd_nonempty() { [[ -n "${1:-}" ]] && valid_fwd_ports "$1"; }
valid_fwd_or_clear() { [[ "${1:-}" == "-" ]] || valid_fwd_ports "${1:-}"; }

tbf_burst() { echo $(($1 * 2 > 64 ? $1 * 2 : 64)); } # burst in kB for a rate in Mbit

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
  for c in curl tar openssl iptables ip systemctl ping; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  if ((missing)); then
    info "Installing required packages..."
    pkg_install curl tar openssl iptables iproute2 iputils-ping -- curl tar openssl iptables iproute iputils || true
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

install_frp() {
  [[ -x "$BIN/frps" && -x "$BIN/frpc" ]] && return 0
  detect_arch || return 1
  local tmp ver url f src
  tmp="$(mktemp -d)"
  info "Finding the latest frp release..."
  ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/fatedier/frp/releases/latest 2>/dev/null \
    | sed -n 's#.*/tag/v\([0-9][0-9.]*\)$#\1#p')"
  if [[ -z "$ver" ]]; then
    rm -rf "$tmp"
    err "Could not find the latest frp version. Check that this server can reach github.com,"
    err "or place the 'frps' and 'frpc' binaries manually in $BIN and retry."
    return 1
  fi
  url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${ARCH}.tar.gz"
  info "Downloading frp $ver ($ARCH)..."
  if ! curl -fsSL --retry 3 -o "$tmp/frp.tgz" "$url"; then
    rm -rf "$tmp"; err "Download failed: $url"; return 1
  fi
  tar -xzf "$tmp/frp.tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; err "Could not extract frp."; return 1; }
  for f in frps frpc; do
    src="$(find "$tmp" -type f -name "$f" | head -n1)"
    [[ -n "$src" ]] || { rm -rf "$tmp"; err "$f not found in the archive."; return 1; }
    install -m 0755 "$src" "$BIN/$f"
  done
  rm -rf "$tmp"
  ok "frp $ver installed."
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

meta_set() { # meta_set name KEY VALUE  (update or add one field)
  local f="$TDIR/$1.meta"
  [[ -f "$f" ]] || return 1
  { grep -v "^$2=" "$f" || true; printf '%s=%q\n' "$2" "$3"; } >"$f.tmp"
  mv "$f.tmp" "$f"
  chmod 600 "$f"
}

load_meta() { # load_meta name
  unset KIND ROLE MODE PORT HOST TOKEN PEER LOCALIP IFACE MTU TTL FWD TARGET PORTS LINKS LIMIT CARRIER LADDR
  # shellcheck disable=SC1090
  source "$TDIR/$1.meta"
}

type_label() { # uses KIND MODE
  if [[ "${KIND:-}" == tun ]]; then echo "tun-${MODE/faketcp/tcp}"; else echo "${MODE:-?}"; fi
}

tunnel_exists() { [[ -f "$TDIR/$1.meta" ]]; }

ask_name() {
  while true; do
    ask_valid name "Tunnel name (a-z, 0-9, dash; max 12 chars)" "tun1" valid_name
    if tunnel_exists "$name"; then warn "A tunnel named '$name' already exists."; else break; fi
  done
}

next_free_net() { # first 10.10.N.0/24 not used by a tunnel on this server
  local n=10 f used
  while ((n < 250)); do
    used=0
    for f in "$TDIR"/*.meta; do
      [[ -f "$f" ]] || continue
      if grep -q "^LADDR=10\.10\.$n\." "$f"; then used=1; break; fi
    done
    ((used)) || break
    n=$((n + 1))
  done
  echo "$n"
}

ask_tun_addrs() { # ask_tun_addrs 4|6   (uses role; sets lcidr rcidr)
  local fam="${1:-4}" dl dr n
  if [[ "$fam" == 6 ]]; then
    if [[ "$role" == server ]]; then dl="fd10:10:10::1/64"; dr="fd10:10:10::2/64"; else dl="fd10:10:10::2/64"; dr="fd10:10:10::1/64"; fi
  else
    n="$(next_free_net)"
    if [[ "$role" == server ]]; then dl="10.10.$n.1/24"; dr="10.10.$n.2/24"; else dl="10.10.$n.2/24"; dr="10.10.$n.1/24"; fi
  fi
  section "TUN Configuration"
  while true; do
    ask_valid lcidr "TUN Local Address (CIDR)" "$dl" "valid_cidr$fam"
    ask_valid rcidr "TUN Remote Address (CIDR)" "$dr" "valid_cidr$fam"
    if [[ "$fam" == 6 ]]; then
      [[ "${lcidr%/*}" != "${rcidr%/*}" ]] && break
      warn "Local and remote addresses must be different."
    else
      same_subnet "$lcidr" "$rcidr" && break
      warn "Local and remote must be two different addresses in the same network (same /length)."
    fi
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

# Port forwarding through a tunnel (server side). Specs: 2052 | 2052/udp | 2052/both | 8443=443[/proto]
gen_fw_script() { # gen_fw_script name target_ip "ports csv"
  local name="$1" target="$2" ports="$3" f="$TDIR/$1.fw"
  local -a specs=()
  local spec base suffix src dst protos proto
  IFS=',' read -ra specs <<<"$ports"
  {
    echo '#!/usr/bin/env bash'
    echo '# usage: fw script up|down'
    echo 'if [[ "${1:-}" == up ]]; then OP=-A; else OP=-D; fi'
    echo 'ipt_fwd() { if [[ "$OP" == -A ]]; then iptables -I FORWARD 1 "$@"; else iptables -D FORWARD "$@"; fi; }'
    echo '[[ "$OP" == -A ]] && sysctl -w net.ipv4.ip_forward=1 >/dev/null'
    for spec in "${specs[@]}"; do
      base="${spec%%/*}"; suffix=""
      [[ "$spec" == */* ]] && suffix="${spec#*/}"
      src="${base%%=*}"; dst="${base##*=}"
      case "$suffix" in
        udp)  protos="udp" ;;
        both) protos="tcp udp" ;;
        *)    protos="tcp" ;;
      esac
      for proto in $protos; do
        echo "iptables -t nat \$OP PREROUTING -p $proto --dport $src -j DNAT --to-destination $target:$dst || true"
      done
    done
    echo "iptables -t nat \$OP POSTROUTING -d $target -j MASQUERADE || true"
    echo "ipt_fwd -d $target -j ACCEPT || true"
    echo "ipt_fwd -s $target -j ACCEPT || true"
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

# uses: name role transport port host token ports links
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
      echo "connection_pool = ${links:-8}"
      echo "aggressive_pool = false"
      echo "retry_interval = 3"
      echo "dial_timeout = 10"
    fi
    if ((mux)); then
      echo "mux_con = ${links:-8}"
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
  save_meta "$name" KIND=stream ROLE="$role" MODE="$transport" PORT="$port" HOST="${host:-}" TOKEN="$token" PORTS="${ports:-}" LINKS="${links:-8}"
  write_unit "$name" "stream tunnel $name ($transport, $role)" <<EOF
Type=simple
ExecStart=$BIN/backhaul -c $TDIR/$name.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
}

# uses: name role transport port host token ports target
gen_frp_conf() {
  local f="$TDIR/$name.toml"
  local -a specs=()
  local spec base suffix src dst protos proto
  {
    if [[ "$role" == server ]]; then
      echo 'bindAddr = "0.0.0.0"'
      echo "bindPort = $port"
      if [[ "$transport" == kcp ]]; then echo "kcpBindPort = $port"; else echo "quicBindPort = $port"; fi
      echo "auth.token = \"$token\""
      echo 'log.level = "info"'
    else
      echo "serverAddr = \"$host\""
      echo "serverPort = $port"
      echo "auth.token = \"$token\""
      echo "transport.protocol = \"$transport\""
      echo 'loginFailExit = false'
      echo 'log.level = "info"'
      IFS=',' read -ra specs <<<"$ports"
      for spec in "${specs[@]}"; do
        base="${spec%%/*}"; suffix=""
        [[ "$spec" == */* ]] && suffix="${spec#*/}"
        src="${base%%=*}"; dst="${base##*=}"
        case "$suffix" in
          udp)  protos="udp" ;;
          both) protos="tcp udp" ;;
          *)    protos="tcp" ;;
        esac
        for proto in $protos; do
          echo
          echo '[[proxies]]'
          echo "name = \"$name-$src-$proto\""
          echo "type = \"$proto\""
          echo "localIP = \"${target:-127.0.0.1}\""
          echo "localPort = $dst"
          echo "remotePort = $src"
        done
      done
    fi
  } >"$f"
  chmod 600 "$f"
}

build_frp() {
  local exe="frpc"
  [[ "$role" == server ]] && exe="frps"
  gen_frp_conf
  save_meta "$name" KIND=frp ROLE="$role" MODE="$transport" PORT="$port" HOST="${host:-}" TOKEN="$token" \
    PORTS="${ports:-}" TARGET="${target:-}"
  write_unit "$name" "$transport tunnel $name ($role)" <<EOF
Type=simple
ExecStart=$BIN/$exe -c $TDIR/$name.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
}

create_frp_tunnel() { # called by create_stream for kcp / quic
  install_frp || return 1
  if [[ "$role" == server ]]; then
    ask_valid port "UDP port to listen on" "3080" valid_port
    ask_valid token "Token (Enter = auto-generate)" "$(gen_token)" valid_token
  else
    ask_valid host "IP or domain of the SERVER side" "" valid_host
    ask_valid port "UDP port of the server" "3080" valid_port
    ask_valid token "Token (must match the server)" "" valid_token
    ask_valid ports "Ports to open on the SERVER (e.g. 2052,8443=443,53/udp)" "" valid_fwd_nonempty
    ask_valid target "Where is the service on THIS server" "127.0.0.1" valid_host
  fi
  build_frp || return 1
  sleep 2
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  if [[ "$role" == server ]]; then
    echo "On the OTHER server create a 'client' tunnel with:"
    echo "  transport : $transport"
    echo "  port      : $port"
    echo "  token     : $token"
    echo "  (it will also ask which ports to open here; open UDP port $port in the firewall)"
  else
    echo "Ports $ports are opened on the server and land on $target here."
    echo "Make sure the server side tunnel (same transport, port and token) is running."
  fi
  return 0
}

create_stream() {
  ensure_base || return 1
  local pick role name transport port host="" token ports="" target="" links=8
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
    "wssmux  - multiplexed WebSocket + TLS" \
    "kcp     - KCP over UDP (low latency, handles loss)" \
    "quic    - QUIC over UDP (needs a clean, low-loss path)"
  transport="${pick%% *}"
  if [[ "$transport" == kcp || "$transport" == quic ]]; then
    create_frp_tunnel
    return $?
  fi
  install_backhaul || return 1
  if [[ "$role" == server ]]; then
    ask_valid port "Tunnel port to listen on" "3080" valid_port
    ask_valid ports "Ports to open for users (e.g. 2052,8443=443,1000-2000)" "" valid_bh_ports
    ask_valid token "Token (Enter = auto-generate)" "$(gen_token)" valid_token
  else
    ask_valid host "IP or domain of the SERVER side" "" valid_host
    ask_valid port "Tunnel port of the server" "3080" valid_port
    ask_valid token "Token (must match the server)" "" valid_token
  fi
  if ask_yes "Advanced options (parallel links)?"; then
    ask_valid links "Parallel links (more links = more resilient to throttling)" "$links" valid_links
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
# uses: name role mode rawport host token lcidr rcidr wgport lport mtu limit fwd target
build_wg() {
  local iface="tt-$name" sp cp psk spub cpub mine peer rawkey
  sp="$(tt_key "srv:$token")"; cp="$(tt_key "cli:$token")"; psk="$(tt_key "psk:$token")"
  rawkey="$(tt_hex "raw:$token")"
  spub="$(printf '%s' "$sp" | wg pubkey)"; cpub="$(printf '%s' "$cp" | wg pubkey)"
  [[ -n "$spub" && -n "$cpub" ]] || { err "Key derivation failed."; return 1; }
  mine="${lcidr%/*}"; peer="${rcidr%/*}"
  [[ -z "${target:-}" ]] && target="$peer"

  mkdir -p "$WG_DIR"
  (
    umask 077
    if [[ "$role" == server ]]; then
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $lcidr
ListenPort = $wgport
PrivateKey = $sp
MTU = $mtu

[Peer]
PublicKey = $cpub
PresharedKey = $psk
AllowedIPs = $peer/32
EOF
    else
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $lcidr
PrivateKey = $cp
MTU = $mtu

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = 127.0.0.1:$lport
AllowedIPs = $peer/32
PersistentKeepalive = 25
EOF
    fi
  )

  local wgq sc raw_args pre="" post="" fw_start="" fw_stop="" tc_line=""
  wgq="$(command -v wg-quick)"; sc="$(command -v sysctl || echo /sbin/sysctl)"
  if ((${limit:-0} > 0)); then
    tc_line="ExecStartPost=-$(command -v tc || echo /sbin/tc) qdisc replace dev $iface root tbf rate ${limit}mbit burst $(tbf_burst "$limit")kb latency 400ms"
  fi
  if [[ "$role" == server ]]; then
    raw_args="-s -l 0.0.0.0:$rawport -r 127.0.0.1:$wgport"
  else
    raw_args="-c -l 127.0.0.1:$lport -r $host:$rawport"
  fi
  if [[ "$mode" == icmp ]]; then
    pre="ExecStartPre=$sc -w net.ipv4.icmp_echo_ignore_all=1"
    post="ExecStopPost=-$sc -w net.ipv4.icmp_echo_ignore_all=0"
  fi
  if [[ "$role" == server ]]; then
    if [[ -n "${fwd:-}" ]]; then gen_fw_script "$name" "$target" "$fwd"; else rm -f "$TDIR/$name.fw"; fi
    fw_start="ExecStartPost=-/bin/sh -c '[ -f $TDIR/$name.fw ] && /bin/bash $TDIR/$name.fw up'"
    fw_stop="ExecStopPost=-/bin/sh -c '[ -f $TDIR/$name.fw ] && /bin/bash $TDIR/$name.fw down'"
  fi

  save_meta "$name" KIND=tun ROLE="$role" MODE="$mode" PORT="$rawport" HOST="${host:-}" TOKEN="$token" \
    PEER="$peer" LADDR="$lcidr" IFACE="$iface" MTU="$mtu" LIMIT="${limit:-0}" FWD="${fwd:-}" TARGET="$target"
  write_unit "$name" "TUN tunnel $name (tun-${mode/faketcp/tcp}, $role)" <<EOF
Type=simple
$pre
ExecStartPre=-$wgq down $iface
ExecStartPre=$wgq up $iface
ExecStart=$BIN/udp2raw $raw_args -k $rawkey --raw-mode $mode --cipher-mode aes128cbc --auth-mode hmac_sha1 -a --keep-rule
$tc_line
$fw_start
ExecStopPost=-$wgq down $iface
$fw_stop
$post
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF
}

# tun-ip: WireGuard running inside a raw-IP carrier (GRE or IPIP).
# uses: name role carrier localip remote token lcidr rcidr mtu limit fwd target
build_tunip() {
  local iface="tt-$name" cif="tc-$name" sp cp psk spub cpub mine peer idx wgport cmine cpeer cmtu mod wgq tcb tcl=""
  local f="$TDIR/$name.sh"
  sp="$(tt_key "srv:$token")"; cp="$(tt_key "cli:$token")"; psk="$(tt_key "psk:$token")"
  spub="$(printf '%s' "$sp" | wg pubkey)"; cpub="$(printf '%s' "$cp" | wg pubkey)"
  [[ -n "$spub" && -n "$cpub" ]] || { err "Key derivation failed."; return 1; }
  idx=$((16#$(tt_hex "ip:$token" | cut -c1-4) % 250 + 1))
  wgport=$((20000 + 16#$(tt_hex "wgp:$token" | cut -c1-4) % 20000))
  cmtu=$((mtu + 80)); ((cmtu > 1500)) && cmtu=1500
  mine="${lcidr%/*}"; peer="${rcidr%/*}"
  if [[ "$role" == server ]]; then
    cmine="100.127.$idx.1"; cpeer="100.127.$idx.2"
  else
    cmine="100.127.$idx.2"; cpeer="100.127.$idx.1"
  fi
  [[ -z "${target:-}" ]] && target="$peer"
  [[ "$carrier" == gre ]] && mod="ip_gre" || mod="ipip"
  wgq="$(command -v wg-quick)"; tcb="$(command -v tc || echo /sbin/tc)"

  mkdir -p "$WG_DIR"
  (
    umask 077
    if [[ "$role" == server ]]; then
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $lcidr
ListenPort = $wgport
PrivateKey = $sp
MTU = $mtu

[Peer]
PublicKey = $cpub
PresharedKey = $psk
AllowedIPs = $peer/32
EOF
    else
      cat >"$WG_DIR/$iface.conf" <<EOF
[Interface]
Address = $lcidr
PrivateKey = $cp
MTU = $mtu

[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $cpeer:$wgport
AllowedIPs = $peer/32
PersistentKeepalive = 25
EOF
    fi
  )

  if [[ "$role" == server && -n "${fwd:-}" ]]; then gen_fw_script "$name" "$target" "$fwd"; else rm -f "$TDIR/$name.fw"; fi
  if ((${limit:-0} > 0)); then
    tcl="  $tcb qdisc replace dev \"\$WGIF\" root tbf rate ${limit}mbit burst $(tbf_burst "$limit")kb latency 400ms"
  fi
  {
    echo '#!/usr/bin/env bash'
    echo "CIF=\"$cif\""
    echo "WGIF=\"$iface\""
    echo "FW=\"$TDIR/$name.fw\""
    echo 'down() {'
    echo '  [[ -f "$FW" ]] && bash "$FW" down >/dev/null 2>&1'
    echo "  $wgq down \"\$WGIF\" >/dev/null 2>&1"
    echo '  ip link del "$CIF" >/dev/null 2>&1'
    echo '  return 0'
    echo '}'
    echo 'up() {'
    echo '  down'
    echo "  modprobe $mod 2>/dev/null"
    echo "  ip link add \"\$CIF\" type $carrier local $localip remote $remote ttl 255 || exit 1"
    echo "  ip addr add $cmine/30 dev \"\$CIF\""
    echo "  ip link set dev \"\$CIF\" mtu $cmtu up"
    echo "  $wgq up \"\$WGIF\" || exit 1"
    [[ -n "$tcl" ]] && echo "$tcl"
    echo '  [[ -f "$FW" ]] && bash "$FW" up'
    echo '  return 0'
    echo '}'
    echo 'case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 1 ;; esac'
  } >"$f"
  chmod 700 "$f"

  save_meta "$name" KIND=tun ROLE="$role" MODE=ip CARRIER="$carrier" HOST="$remote" LOCALIP="$localip" TOKEN="$token" \
    PEER="$peer" LADDR="$lcidr" IFACE="$iface" MTU="$mtu" LIMIT="${limit:-0}" FWD="${fwd:-}" TARGET="$target"
  write_unit "$name" "TUN tunnel $name (tun-ip over $carrier, $role)" <<EOF
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $f up
ExecStop=/bin/bash $f down
EOF
}

create_tun() {
  ensure_base || return 1
  ensure_wireguard || return 1
  local pick role name mode rawport="" host="" token lcidr="" rcidr="" wgport lport fwd="" target="" mtu=1200 limit=0
  local carrier="gre" localip="" remote=""
  choose pick "Which side is this server?" \
    "server - listens for the tunnel (usually the Iran side)" \
    "client - dials in to the server (usually the foreign side)"
  role="${pick%% *}"
  ask_name
  choose pick "Tunnel type:" \
    "tun-tcp  - private network over fake-TCP packets" \
    "tun-udp  - private network over UDP packets" \
    "tun-icmp - private network over ICMP (ping) packets" \
    "tun-ip   - private network over raw IP packets (GRE / IPIP)"
  case "${pick%% *}" in
    tun-tcp) mode="faketcp" ;;
    tun-udp) mode="udp" ;;
    tun-icmp) mode="icmp" ;;
    *)       mode="ip" ;;
  esac
  if [[ "$mode" == ip ]]; then
    mtu=1360
    choose pick "IP carrier:" \
      "gre  - IP protocol 47 (works almost everywhere)" \
      "ipip - IP protocol 4 (smaller overhead)"
    carrier="${pick%% *}"
    ask_valid localip "This server's real IP" "$(default_local_ip)" valid_ipv4
    ask_valid remote "The OTHER server's real IP" "" valid_ipv4
    if [[ "$role" == server ]]; then
      ask_valid token "Token / password (min 16 chars, Enter = auto-generate)" "$(gen_token)" valid_token
    else
      ask_valid token "Token (must match the server)" "" valid_token
    fi
  else
    install_udp2raw || return 1
    if [[ "$role" == server ]]; then
      ask_valid rawport "Port to listen on (ignored by ICMP, still required)" "443" valid_port
      ask_valid token "Token / password (min 16 chars, Enter = auto-generate)" "$(gen_token)" valid_token
    else
      ask_valid host "Public IP of the SERVER side" "" valid_ipv4
      ask_valid rawport "Port of the server" "443" valid_port
      ask_valid token "Token (must match the server)" "" valid_token
    fi
  fi
  ask_tun_addrs 4
  if ask_yes "Advanced options (MTU, speed limit)?"; then
    ask_valid mtu "MTU" "$mtu" valid_mtu
    ask_valid limit "Speed limit in Mbps (0 = off)" "0" valid_limit
  fi
  wgport=$((20000 + RANDOM % 20000)); lport=$((40000 + RANDOM % 20000))
  if [[ "$role" == server ]]; then
    ask_valid fwd "Ports to forward through the tunnel (e.g. 2052,8443=443,53/udp; Enter = none)" "" valid_fwd_ports
    if [[ -n "$fwd" ]]; then
      ask_valid target "Deliver them to (address on the other side)" "${rcidr%/*}" valid_ipv4
    fi
  fi
  if [[ "$mode" == ip ]]; then build_tunip || return 1; else build_wg || return 1; fi
  sleep 3
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  echo "On the OTHER server create a '$([[ $role == server ]] && echo client || echo server)' TUN tunnel with:"
  echo "  type    : tun-${mode/faketcp/tcp}"
  if [[ "$mode" == ip ]]; then
    echo "  carrier : $carrier"
    echo "  IPs     : its own real IP, and this server's real IP ($localip) as the OTHER server"
  else
    echo "  port    : $rawport"
  fi
  echo "  token   : $token"
  echo "  TUN Local Address  : $rcidr"
  echo "  TUN Remote Address : $lcidr"
  if [[ "$mode" != ip && "$role" == server ]]; then
    echo "  (the client needs this server's public IP; open port $rawport in the firewall)"
  fi
  if [[ "$mode" == ip ]]; then
    warn "Your provider/firewall must allow the protocol ($carrier) between both servers."
  fi
  if [[ -n "$fwd" ]]; then
    echo
    echo "Forwarding $fwd -> ${target:-${rcidr%/*}}: the service on the other side must listen on that address (or 0.0.0.0)."
  fi
  echo "Then run 'Manage tunnels -> Health check' to test the link."
  [[ "$mode" == icmp ]] && warn "ICMP mode makes this server ignore normal pings while the tunnel runs."
  return 0
}

# ---------------------------------------------------------------------
#  3) Kernel tunnels (GRE / GRETAP / IPIP / SIT / L2TPv3)
# ---------------------------------------------------------------------
default_local_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }

# uses: name role mode localip remote lcidr rcidr mtu ttl limit gkey l2enc l2port l2id fwd target
build_kernel() {
  local iface="tt-$name" addr peer f="$TDIR/$name.sh" keyopt="" T PT S PS
  addr="$lcidr"; peer="${rcidr%/*}"
  [[ -n "${gkey:-}" ]] && keyopt=" key $gkey"
  [[ -z "${target:-}" ]] && target="$peer"
  if [[ "$role" == server && "$mode" != sit && -n "${fwd:-}" ]]; then
    gen_fw_script "$name" "$target" "$fwd"
  else
    rm -f "$TDIR/$name.fw"
  fi
  if [[ "$role" == server ]]; then T=$l2id; PT=$((l2id + 1)); else T=$((l2id + 1)); PT=$l2id; fi
  S=$T; PS=$PT

  {
    echo '#!/usr/bin/env bash'
    echo "IFACE=\"$iface\""
    echo "FW=\"$TDIR/$name.fw\""
    echo 'down() {'
    echo '  [[ -f "$FW" ]] && bash "$FW" down >/dev/null 2>&1'
    if [[ "$mode" == l2tp ]]; then
      echo "  ip l2tp del session tunnel_id $T session_id $S >/dev/null 2>&1"
      echo "  ip l2tp del tunnel tunnel_id $T >/dev/null 2>&1"
    else
      echo '  ip link del "$IFACE" >/dev/null 2>&1'
    fi
    echo '  return 0'
    echo '}'
    echo 'up() {'
    echo '  down'
    case "$mode" in
      gre | gretap) echo '  modprobe ip_gre 2>/dev/null' ;;
      ipip)         echo '  modprobe ipip 2>/dev/null' ;;
      sit)          echo '  modprobe sit 2>/dev/null' ;;
      l2tp)
        echo '  modprobe l2tp_eth 2>/dev/null; modprobe l2tp_netlink 2>/dev/null'
        [[ "$l2enc" == ip ]] && echo '  modprobe l2tp_ip 2>/dev/null'
        ;;
    esac
    if [[ "$mode" == l2tp ]]; then
      if [[ "$l2enc" == udp ]]; then
        echo "  ip l2tp add tunnel tunnel_id $T peer_tunnel_id $PT encap udp local $localip remote $remote udp_sport $l2port udp_dport $l2port || exit 1"
      else
        echo "  ip l2tp add tunnel tunnel_id $T peer_tunnel_id $PT encap ip local $localip remote $remote || exit 1"
      fi
      echo "  ip l2tp add session name \"\$IFACE\" tunnel_id $T session_id $S peer_session_id $PS || exit 1"
    else
      echo "  ip link add \"\$IFACE\" type $mode local $localip remote $remote ttl $ttl$keyopt || exit 1"
    fi
    if [[ "$mode" == sit ]]; then
      echo "  ip -6 addr add $addr dev \"\$IFACE\""
    else
      echo "  ip addr add $addr dev \"\$IFACE\""
    fi
    echo "  ip link set dev \"\$IFACE\" mtu $mtu up"
    if ((${limit:-0} > 0)); then
      echo "  $(command -v tc || echo /sbin/tc) qdisc replace dev \"\$IFACE\" root tbf rate ${limit}mbit burst $(tbf_burst "$limit")kb latency 400ms"
    fi
    echo '  [[ -f "$FW" ]] && bash "$FW" up'
    echo '  return 0'
    echo '}'
    echo 'case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down"; exit 1 ;; esac'
  } >"$f"
  chmod 700 "$f"

  save_meta "$name" KIND=kernel ROLE="$role" MODE="$mode" HOST="$remote" LOCALIP="$localip" PEER="$peer" LADDR="$lcidr" \
    IFACE="$iface" MTU="$mtu" TTL="$ttl" LIMIT="${limit:-0}" FWD="${fwd:-}" TARGET="$target"
  write_unit "$name" "kernel tunnel $name ($mode, $role)" <<EOF
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $f up
ExecStop=/bin/bash $f down
EOF
}

create_kernel() {
  ensure_base || return 1
  local pick role name mode localip remote lcidr="" rcidr="" fwd="" target=""
  local mtu=1400 ttl=255 limit=0 gkey="" l2enc="udp" l2port=5555 l2id=1000
  choose pick "Which side is this server?" \
    "server - usually the Iran side (default address .1)" \
    "client - usually the foreign side (default address .2)"
  role="${pick%% *}"
  ask_name
  choose pick "Tunnel type:" \
    "gre    - GRE, layer 3 (highest throughput)" \
    "gretap - GRE, layer 2 (Ethernet over GRE)" \
    "ipip   - IP-in-IP (lowest overhead, IPv4 only)" \
    "sit    - 6in4 (IPv6 over IPv4)" \
    "l2tp   - L2TPv3 (over UDP or raw IP)"
  mode="${pick%% *}"
  ask_valid localip "This server's real IP" "$(default_local_ip)" valid_ipv4
  ask_valid remote "The OTHER server's real IP" "" valid_ipv4
  if [[ "$mode" == sit ]]; then ask_tun_addrs 6; else ask_tun_addrs 4; fi
  if ask_yes "Advanced options (MTU, TTL, speed limit, keys, ids)?"; then
    ask_valid mtu "MTU" "$mtu" valid_mtu
    ask_valid limit "Speed limit in Mbps (0 = off)" "0" valid_limit
    if [[ "$mode" != l2tp ]]; then
      ask_valid ttl "TTL" "$ttl" valid_ttl
    fi
    if [[ "$mode" == gre || "$mode" == gretap ]]; then
      ask_valid gkey "GRE key (a number, Enter = none; same on both sides)" "" valid_key
    fi
    if [[ "$mode" == l2tp ]]; then
      choose pick "L2TP encapsulation:" \
        "udp - works through most NATs" \
        "ip  - raw IP, lower overhead"
      l2enc="${pick%% *}"
      if [[ "$l2enc" == udp ]]; then
        ask_valid l2port "L2TP UDP port (same on both sides)" "$l2port" valid_port
      fi
      ask_valid l2id "L2TP id (same on both sides)" "$l2id" valid_id
    fi
  fi
  if [[ "$role" == server && "$mode" != sit ]]; then
    ask_valid fwd "Ports to forward through the tunnel (e.g. 2052,8443=443,53/udp; Enter = none)" "" valid_fwd_ports
    if [[ -n "$fwd" ]]; then
      ask_valid target "Deliver them to (address on the other side)" "${rcidr%/*}" valid_ipv4
    fi
  fi
  build_kernel || return 1
  sleep 1
  ok "Tunnel '$name' created. Service: $(systemctl is-active "$APP-$name.service")"
  echo
  echo "On the OTHER server create the opposite side with the same type and options, and:"
  echo "  TUN Local Address  : $rcidr"
  echo "  TUN Remote Address : $lcidr"
  if [[ -n "$fwd" ]]; then
    echo "Forwarding $fwd -> ${target:-${rcidr%/*}}: the service on the other side must listen on that address (or 0.0.0.0)."
  fi
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
    printf '%-14s %-8s %-8s %-10s %s\n' "$n" "$KIND" "$ROLE" "$(type_label)" "$(status_of "$n")"
  done
}

delete_tunnel() {
  local n="$1"
  load_meta "$n"
  systemctl disable --now "$APP-$n.service" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$APP-$n.service"
  systemctl daemon-reload
  if [[ "$KIND" == tun ]]; then
    wg-quick down "tt-$n" >/dev/null 2>&1
    rm -f "$WG_DIR/tt-$n.conf"
  fi
  [[ -f "$TDIR/$n.fw" ]] && bash "$TDIR/$n.fw" down >/dev/null 2>&1
  [[ -f "$TDIR/$n.sh" ]] && bash "$TDIR/$n.sh" down >/dev/null 2>&1
  rm -f "$TDIR/$n".{meta,toml,fw,sh} "$CONF/certs/$n".{crt,key}
  ok "Tunnel '$n' removed."
}

health_check() { # health_check peer_ip
  local peer="$1" out loss rtt vals mn av mx jt
  local -a cmd=(ping -c 20 -i 0.2 -W 2)
  command -v ping >/dev/null 2>&1 || { err "'ping' is not installed."; return 1; }
  [[ "$peer" == *:* ]] && cmd+=(-6)
  info "Sending 20 pings through the tunnel to $peer ..."
  out="$("${cmd[@]}" "$peer" 2>&1)" || true
  loss="$(grep -oE '[0-9.]+% packet loss' <<<"$out" | head -n1)"
  rtt="$(grep -E '^(rtt|round-trip)' <<<"$out" | head -n1)"
  if [[ -z "$rtt" ]]; then
    err "No replies. Is the other side created and running? Check the firewall and the logs."
    return 1
  fi
  vals="${rtt#*= }"; vals="${vals%% *}"
  IFS=/ read -r mn av mx jt <<<"$vals"
  echo "Loss    : ${loss:-unknown}"
  echo "Latency : min $mn / avg $av / max $mx ms"
  echo "Jitter  : $jt ms"
  if [[ "${loss%%%*}" != "0" && "${loss%%%*}" != "0.0" ]]; then
    warn "Packet loss detected. Try another tunnel type, a lower MTU, or another port."
  elif awk -v j="$jt" 'BEGIN{exit !(j+0 > 10)}'; then
    warn "Jitter is high (> 10 ms). Games and calls will feel unstable."
  else
    ok "The link looks healthy."
  fi
}

test_tunnel() {
  local n="$1"
  load_meta "$n"
  if [[ "$KIND" == stream || "$KIND" == frp ]]; then
    echo "Service: $(status_of "$n")"
    if [[ "$ROLE" == server ]]; then ss -lntu 2>/dev/null | grep -E ":$PORT\b" || warn "Nothing is listening on $PORT."; fi
    journalctl -u "$APP-$n.service" -n 8 --no-pager 2>/dev/null
  else
    health_check "$PEER"
  fi
}

show_info() {
  local n="$1"
  load_meta "$n"
  echo "Name    : $n"
  echo "Kind    : $KIND"
  echo "Role    : $ROLE"
  echo "Type    : $(type_label)"
  [[ -n "${HOST:-}" ]] && echo "Remote  : $HOST"
  [[ -n "${LOCALIP:-}" ]] && echo "Local   : $LOCALIP"
  [[ -n "${PORT:-}" ]] && echo "Port    : $PORT"
  [[ -n "${LADDR:-}" ]] && echo "Address : $LADDR"
  [[ -n "${PEER:-}" ]] && echo "Peer    : $PEER (tunnel address)"
  [[ -n "${CARRIER:-}" ]] && echo "Carrier : $CARRIER"
  [[ -n "${MTU:-}" ]] && echo "MTU     : $MTU"
  [[ "${LIMIT:-0}" != "0" && -n "${LIMIT:-}" ]] && echo "Limit   : $LIMIT Mbps"
  [[ -n "${TTL:-}" ]] && echo "TTL     : $TTL"
  [[ -n "${PORTS:-}" ]] && echo "Ports   : $PORTS"
  [[ -n "${LINKS:-}" ]] && echo "Links   : $LINKS"
  [[ "$KIND" == frp && -n "${TARGET:-}" ]] && echo "Lands on: $TARGET (this server)"
  [[ -n "${FWD:-}" ]] && echo "Forward : $FWD -> ${TARGET:-$PEER}"
  [[ -n "${TOKEN:-}" ]] && echo "Token   : $TOKEN"
  echo "Status  : $(status_of "$n")"
}

edit_ports() { # edit_ports name
  local n="$1" newp="" cur target
  load_meta "$n"
  if [[ "$KIND" == frp ]]; then
    [[ "$ROLE" == client ]] || { warn "For kcp/quic tunnels the ports are set on the client side."; return 1; }
  else
    [[ "$ROLE" == server ]] || { warn "Only the server side opens ports."; return 1; }
  fi
  case "$KIND" in
    frp)
      cur="${PORTS:-}"
      ask_valid newp "Ports to open on the server" "$cur" valid_fwd_nonempty
      {
        local name="$n" role="$ROLE" transport="$MODE" port="$PORT" host="${HOST:-}" token="$TOKEN" ports="$newp" target="${TARGET:-127.0.0.1}"
        gen_frp_conf
      }
      meta_set "$n" PORTS "$newp"
      systemctl restart "$APP-$n.service" && ok "Ports updated and tunnel restarted."
      ;;
    stream)
      cur="${PORTS:-}"
      ask_valid newp "Ports to open for users" "$cur" valid_bh_ports
      {
        local name="$n" role="$ROLE" transport="$MODE" port="$PORT" host="${HOST:-}" token="$TOKEN" ports="$newp" links="${LINKS:-8}"
        gen_backhaul_conf
      }
      meta_set "$n" PORTS "$newp"
      systemctl restart "$APP-$n.service" && ok "Ports updated and tunnel restarted."
      ;;
    tun | kernel)
      if [[ "$MODE" == sit ]]; then warn "Port forwarding is not available for sit tunnels."; return 1; fi
      cur="${FWD:-}"
      ask_valid newp "Forwarded ports ('-' clears all)" "$cur" valid_fwd_or_clear
      [[ "$newp" == "-" ]] && newp=""
      target="${TARGET:-$PEER}"
      if [[ -n "$newp" ]]; then ask_valid target "Deliver them to (address on the other side)" "$target" valid_ipv4; fi
      [[ -f "$TDIR/$n.fw" ]] && bash "$TDIR/$n.fw" down >/dev/null 2>&1
      if [[ -n "$newp" ]]; then gen_fw_script "$n" "$target" "$newp"; else rm -f "$TDIR/$n.fw"; fi
      meta_set "$n" FWD "$newp"
      meta_set "$n" TARGET "$target"
      if [[ "$(status_of "$n")" == active && -f "$TDIR/$n.fw" ]]; then bash "$TDIR/$n.fw" up; fi
      ok "Forwarded ports updated."
      ;;
  esac
}

can_edit_ports() { # uses KIND ROLE (after load_meta)
  if [[ "${KIND:-}" == frp ]]; then [[ "${ROLE:-}" == client ]]; else [[ "${ROLE:-}" == server ]]; fi
}

mi() { # mi color number "text" ["hint"]
  printf ' %s%s.%s %s%s\n' "$1" "$2" "$C_0" "$3" "${4:+  ${C_D}$4${C_0}}"
}

tunnel_menu() {
  local n="$1" pick yn
  while true; do
    load_meta "$n"
    section "Tunnel: $n ($(status_of "$n"))"
    mi "$C_G" 1 "Info"
    mi "$C_G" 2 "Restart"
    mi "$C_Y" 3 "Stop"
    mi "$C_G" 4 "Logs"
    mi "$C_G" 5 "Live logs"
    mi "$C_G" 6 "Health check" "loss, latency, jitter"
    if can_edit_ports; then mi "$C_G" 7 "Edit ports"; fi
    mi "$C_R" 8 "Delete tunnel"
    mi "$C_B" 0 "Back"
    printf '%s' "${C_B}[-]${C_0} Enter your choice [0-8]: "
    IFS= read -r pick || die "Input closed."
    case "$pick" in
      1) show_info "$n" ;;
      2) systemctl restart "$APP-$n.service" && ok "Restarted." ;;
      3) systemctl stop "$APP-$n.service" && ok "Stopped." ;;
      4) journalctl -u "$APP-$n.service" -n 60 --no-pager ;;
      5) trap 'true' INT; journalctl -fu "$APP-$n.service"; trap - INT ;;
      6) test_tunnel "$n" ;;
      7) if can_edit_ports; then edit_ports "$n"; else warn "Invalid choice."; fi ;;
      8) ask yn "Type 'yes' to delete '$n'" ""; if [[ "$yn" == yes ]]; then delete_tunnel "$n"; return; fi ;;
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
#  Network tuning (optional, reversible)
# ---------------------------------------------------------------------
TUNE_FILE="${TT_TUNE_FILE:-/etc/sysctl.d/99-toolstunnel.conf}"
TUNE_MODLOAD="${TT_TUNE_MODLOAD:-/etc/modules-load.d/toolstunnel.conf}"
TUNE_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.netdev_max_backlog net.core.somaxconn)

tune_backup() {
  local bk="$CONF/sysctl-backup.conf" k v
  [[ -f "$bk" ]] && return 0
  mkdir -p "$CONF"
  : >"$bk"
  for k in "${TUNE_KEYS[@]}"; do
    v="$(sysctl -n "$k" 2>/dev/null)" && printf '%s = %s\n' "$k" "$v" >>"$bk"
  done
}

tune_apply() { # tune_apply balanced|fast|latency
  local prof="$1" bbr=0 qd mem backlog
  case "$prof" in
    fast)    qd="fq";       mem=33554432; backlog=16384 ;;
    latency) qd="fq_codel"; mem=4194304;  backlog=4096 ;;
    *)       qd="fq";       mem=16777216; backlog=8192 ;;
  esac
  tune_backup
  modprobe tcp_bbr 2>/dev/null
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr && bbr=1
  {
    echo "# Toolstunnel network tuning - profile: $prof"
    echo "net.core.default_qdisc = $qd"
    ((bbr)) && echo "net.ipv4.tcp_congestion_control = bbr"
    echo "net.core.rmem_max = $mem"
    echo "net.core.wmem_max = $mem"
    echo "net.ipv4.tcp_rmem = 4096 131072 $mem"
    echo "net.ipv4.tcp_wmem = 4096 65536 $mem"
    echo "net.core.netdev_max_backlog = $backlog"
    echo "net.core.somaxconn = 4096"
  } >"$TUNE_FILE"
  if ((bbr)); then
    mkdir -p "$(dirname "$TUNE_MODLOAD")"
    echo "tcp_bbr" >"$TUNE_MODLOAD"
  fi
  sysctl -p "$TUNE_FILE" >/dev/null 2>&1
  ok "Profile '$prof' applied$( ((bbr)) && echo ' (BBR on)' || echo ' (BBR not available on this kernel)')."
}

tune_reset() {
  local bk="$CONF/sysctl-backup.conf"
  [[ -f "$bk" ]] && sysctl -p "$bk" >/dev/null 2>&1
  rm -f "$TUNE_FILE" "$TUNE_MODLOAD" "$bk"
  ok "Previous network settings restored."
}

tune_menu() {
  local pick
  warn "This changes kernel network settings for the WHOLE server. 'reset' restores the old values."
  choose pick "Network tuning profile:" \
    "balanced - BBR + fq, moderate buffers (safe default)" \
    "fast     - big buffers for high-bandwidth links" \
    "latency  - small buffers + fq_codel (games, calls)" \
    "reset    - restore the previous values" \
    "<- back"
  case "${pick%% *}" in
    balanced | fast | latency) tune_apply "${pick%% *}" ;;
    reset) tune_reset ;;
    *) return 0 ;;
  esac
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
load_ipinfo() { # one lookup per run; set TT_NO_IPINFO=1 to disable
  [[ -n "${IPINFO_DONE:-}" ]] && return 0
  IPINFO_DONE=1; IP_ADDR=""; IP_LOC=""; IP_DC=""
  if [[ -z "${TT_NO_IPINFO:-}" ]] && command -v curl >/dev/null 2>&1; then
    local j city country
    j="$(curl -fsS --max-time 3 https://ipinfo.io/json 2>/dev/null)" || j=""
    IP_ADDR="$(printf '%s\n' "$j" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p' | head -n1)"
    city="$(printf '%s\n' "$j" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' | head -n1)"
    country="$(printf '%s\n' "$j" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -n1)"
    IP_DC="$(printf '%s\n' "$j" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' | head -n1)"
    IP_LOC="${city:+$city, }$country"
  fi
  [[ -n "$IP_ADDR" ]] || IP_ADDR="$(default_local_ip)"
  [[ -n "$IP_LOC" && "$IP_LOC" != ", " ]] || IP_LOC="unknown"
  [[ -n "$IP_DC" ]] || IP_DC="unknown"
}

core_flag() { # core_flag command
  if [[ -x "$BIN/$1" ]] || command -v "$1" >/dev/null 2>&1; then printf '%s' "${C_G}✓${C_0}"; else printf '%s' "${C_D}✗${C_0}"; fi
}

hr() { printf '%s\n' "${C_O}════════════════════════════════════════════${C_0}"; }

banner() {
  local total active n
  [[ -t 1 ]] && clear 2>/dev/null
  load_ipinfo
  list_tunnels; total=${#TUNNELS[@]}; active=0
  for n in "${TUNNELS[@]}"; do [[ "$(status_of "$n")" == active ]] && active=$((active + 1)); done
  echo
  echo "${C_BB}╔╦╗╔═╗╔═╗╦  ╔═╗╔╦╗╦ ╦╔╗╔╔╗╔╔═╗╦  ${C_0}"
  echo "${C_BB} ║ ║ ║║ ║║  ╚═╗ ║ ║ ║║║║║║║║╣ ║  ${C_0}"
  echo "${C_BB} ╩ ╚═╝╚═╝╩═╝╚═╝ ╩ ╚═╝╝╚╝╝╚╝╚═╝╩═╝${C_0}"
  echo "${C_B}Reverse tunnel manager for Linux servers${C_0}"
  echo
  echo "${C_G}Script Version:${C_0} ${C_Y}v$VERSION${C_0}"
  echo "${C_G}Cores:${C_0} Backhaul $(core_flag backhaul)  frp $(core_flag frps)  udp2raw $(core_flag udp2raw)  WireGuard $(core_flag wg)"
  hr
  echo "${C_G}IP Address:${C_0} ${C_Y}$IP_ADDR${C_0}"
  echo "${C_G}Location:${C_0} ${C_Y}$IP_LOC${C_0}"
  echo "${C_G}Datacenter:${C_0} ${C_Y}$IP_DC${C_0}"
  echo "${C_G}Tunnels:${C_0} ${C_Y}$total${C_0} (${C_Y}$active${C_0} active)"
  hr
  echo
}

main_menu() {
  need_root
  mkdir -p "$TDIR"
  local pick
  while true; do
    banner
    mi "$C_G" 1 "Create stream tunnel" "tcpmux, ws, wss, kcp, quic ..."
    mi "$C_G" 2 "Create TUN tunnel" "tun-tcp, tun-udp, tun-icmp, tun-ip"
    mi "$C_G" 3 "Create kernel tunnel" "GRE, GRETAP, IPIP, SIT, L2TP"
    mi "$C_Y" 4 "Manage tunnels"
    mi "$C_B" 5 "Tunnel status"
    mi "$C_B" 6 "Network tuning" "BBR, buffers (optional)"
    mi "$C_B" 7 "Update script"
    mi "$C_R" 8 "Remove Toolstunnel"
    mi "$C_B" 0 "Exit"
    echo "${C_G}────────────────────────────────────────────${C_0}"
    printf '%s' "${C_B}[-]${C_0} Enter your choice [0-8]: "
    IFS= read -r pick || exit 0
    case "$pick" in
      1) create_stream; pause ;;
      2) create_tun; pause ;;
      3) create_kernel; pause ;;
      4) manage_tunnels ;;
      5) show_status_all; pause ;;
      6) tune_menu; pause ;;
      7) update_script; pause ;;
      8) uninstall_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    -v | --version | version) echo "Toolstunnel $VERSION" ;;
    status | list) need_root; show_status_all ;;
    *) main_menu ;;
  esac
fi
