#!/bin/sh

NETBIRD_ROOT="/data/netbird"
readonly NETBIRD_ROOT
MARKER_BEGIN="# BEGIN netbird-unifi managed environment"
MARKER_END="# END netbird-unifi managed environment"
LEGACY_MARKER="# netbird-unifi managed environment"

if [ "${NETBIRD_UNIFI_TESTING:-false}" = true ]; then
  ENV_FILE="${ENV_FILE:-$NETBIRD_ROOT/netbird-env}"
  UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  SYSCONFIG="${SYSCONFIG_FILE:-/etc/sysconfig/netbird}"
  APT_SOURCE="${APT_SOURCE:-/etc/apt/sources.list.d/netbird.list}"
  APT_KEY="${APT_KEY:-/usr/share/keyrings/netbird-archive-keyring.gpg}"
  PORT_FILE="${PORT_FILE:-$NETBIRD_ROOT/.applied-wireguard-port}"
  LOCK="${LOCK_DIR:-$NETBIRD_ROOT/.manage.lock}"
  BOOT_HOOK="${BOOT_HOOK_FILE:-/data/on_boot.d/20-netbird.sh}"
else
  ENV_FILE="$NETBIRD_ROOT/netbird-env"
  UNIT_DIR="/etc/systemd/system"
  SYSCONFIG="/etc/sysconfig/netbird"
  APT_SOURCE="/etc/apt/sources.list.d/netbird.list"
  APT_KEY="/usr/share/keyrings/netbird-archive-keyring.gpg"
  PORT_FILE="$NETBIRD_ROOT/.applied-wireguard-port"
  LOCK="$NETBIRD_ROOT/.manage.lock"
  BOOT_HOOK="/data/on_boot.d/20-netbird.sh"
fi

log(){ printf '%s\n' "$*"; }
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }
need(){ has "$1" || fail "Missing required command: $1"; }

validate_config_value(){
  vcv_name="$1"; vcv_value="$2"; vcv_cr="$(printf '\r')"
  case "$vcv_value" in
    *'
'*|*"$vcv_cr"*) fail "$vcv_name cannot contain line breaks";;
  esac
}

# Double-quote escaping is literal in both POSIX shell files and systemd
# EnvironmentFile syntax.
write_config_value(){
  wcv_key="$1"; wcv_value="$2"
  validate_config_value "$wcv_key" "$wcv_value"
  wcv_escaped="$(printf '%s' "$wcv_value" | sed 's/[\\`"$]/\\&/g')"
  printf '%s="%s"\n' "$wcv_key" "$wcv_escaped"
}

# Replace one known assignment without interpolating the value into a command.
set_config_value(){
  scv_file="$1"; scv_key="$2"; scv_value="$3"; scv_found=false
  [ -n "$scv_value" ] || return 0
  validate_config_value "$scv_key" "$scv_value"
  scv_tmp="$scv_file.tmp.$$"
  : >"$scv_tmp"
  while IFS= read -r scv_line || [ -n "$scv_line" ]; do
    case "$scv_line" in
      "$scv_key"=*) write_config_value "$scv_key" "$scv_value" >>"$scv_tmp"; scv_found=true;;
      *) printf '%s\n' "$scv_line" >>"$scv_tmp";;
    esac
  done <"$scv_file"
  [ "$scv_found" = true ] || { rm -f "$scv_tmp"; fail "Missing configuration key: $scv_key"; }
  chmod 0600 "$scv_tmp"; mv -f "$scv_tmp" "$scv_file"
}

load_env(){
  [ -f "$ENV_FILE" ] || fail "Missing $ENV_FILE"
  [ ! -L "$ENV_FILE" ] || fail "Refusing to source symlinked $ENV_FILE"
  unset NB_STATE_DIR NB_HOSTNAME NB_MANAGEMENT_URL NB_INTERFACE_NAME NB_WIREGUARD_PORT \
    NB_DISABLE_EBPF_WG_PROXY NETBIRD_DNS_MODE NETBIRD_ROUTING_MODE NETBIRD_AUTOUPDATE \
    NB_USE_LEGACY_ROUTING NB_DISABLE_CUSTOM_ROUTING 2>/dev/null || true
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  : "${NB_STATE_DIR:=$NETBIRD_ROOT/state}"
  : "${NB_HOSTNAME:=netbird-unifi}"
  : "${NB_MANAGEMENT_URL:=https://api.netbird.io:443}"
  : "${NB_INTERFACE_NAME:=netbird0}"
  : "${NB_WIREGUARD_PORT:=41642}"
  : "${NB_DISABLE_EBPF_WG_PROXY:=true}"
  : "${NETBIRD_DNS_MODE:=unmanaged}"
  : "${NETBIRD_ROUTING_MODE:=auto}"
  : "${NETBIRD_AUTOUPDATE:=false}"
  export NB_STATE_DIR NB_MANAGEMENT_URL NB_DISABLE_EBPF_WG_PROXY
  unset NB_USE_LEGACY_ROUTING NB_DISABLE_CUSTOM_ROUTING 2>/dev/null || true
  if [ "$NETBIRD_ROUTING_MODE" = legacy ]; then
    NB_USE_LEGACY_ROUTING=true
    export NB_USE_LEGACY_ROUTING
  fi
}

validate_env(){
  case "$NB_WIREGUARD_PORT" in ''|*[!0-9]*|??????*) fail "NB_WIREGUARD_PORT must be an integer from 1 to 65535";; esac
  if [ "$NB_WIREGUARD_PORT" -lt 1 ] || [ "$NB_WIREGUARD_PORT" -gt 65535 ]; then fail "NB_WIREGUARD_PORT must be 1..65535"; fi
  case "$NB_MANAGEMENT_URL" in http://*|https://*) :;; *) fail "NB_MANAGEMENT_URL must be http(s)://";; esac
  validate_config_value NB_MANAGEMENT_URL "$NB_MANAGEMENT_URL"
  [ "$NB_STATE_DIR" = /data/netbird/state ] || fail "NB_STATE_DIR must be /data/netbird/state"
  case "$NB_INTERFACE_NAME" in ''|*[!A-Za-z0-9_.:-]*) fail "Invalid NB_INTERFACE_NAME";; esac
  case "$NB_HOSTNAME" in ''|*[!A-Za-z0-9._-]*) fail "Invalid NB_HOSTNAME";; esac
  case "$NB_DISABLE_EBPF_WG_PROXY" in true|false) :;; *) fail "NB_DISABLE_EBPF_WG_PROXY must be true/false";; esac
  case "$NETBIRD_DNS_MODE" in managed|unmanaged) :;; *) fail "NETBIRD_DNS_MODE must be managed/unmanaged";; esac
  case "$NETBIRD_ROUTING_MODE" in auto|modern|legacy) :;; *) fail "NETBIRD_ROUTING_MODE must be auto/legacy";; esac
  case "$NETBIRD_AUTOUPDATE" in true|false) :;; *) fail "NETBIRD_AUTOUPDATE must be true/false";; esac
}

preflight(){
  [ "$(id -u)" -eq 0 ] || fail "Run as root"
  need systemctl; need dpkg-query; need cmp; need readlink
  load_env; validate_env
}
preflight_runtime(){ preflight; [ -c /dev/net/tun ] || fail "/dev/net/tun is required"; }
preflight_package(){
  preflight_runtime; need apt-get; need curl
  if ! has gpg; then apt-get update; apt-get install -y ca-certificates gnupg; fi
  need gpg
}
preflight_cleanup(){
  [ "$(id -u)" -eq 0 ] || fail "Run as root"
  need systemctl; need dpkg-query
}

validate_purge_root(){
  [ "$1" = /data/netbird ] || fail "Refusing to purge unexpected path: $1"
}
validate_purge_target(){
  validate_purge_root "$1"
  [ ! -L /data/netbird ] || fail "Refusing to purge a symlinked /data/netbird"
}

acquire_lock(){
  [ ! -L "$NETBIRD_ROOT" ] || fail "Refusing to use symlinked $NETBIRD_ROOT"
  mkdir -p "$(dirname "$LOCK")"
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" >"$LOCK/pid"; trap 'rm -rf "$LOCK"' EXIT INT TERM HUP; return; fi
  p="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$LOCK"; mkdir "$LOCK"; printf '%s\n' "$$" >"$LOCK/pid"; trap 'rm -rf "$LOCK"' EXIT INT TERM HUP; return; fi
  fail "Another lifecycle operation is running${p:+ (PID $p)}"
}
release_lock(){ rm -rf "$LOCK"; trap - EXIT INT TERM HUP; }
ensure_state(){
  [ ! -L "$NETBIRD_ROOT" ] || fail "Refusing to use symlinked $NETBIRD_ROOT"
  [ ! -L "$NB_STATE_DIR" ] || fail "Refusing to use symlinked $NB_STATE_DIR"
  [ ! -L "$ENV_FILE" ] || fail "Refusing to use symlinked $ENV_FILE"
  mkdir -p "$NB_STATE_DIR"; chmod 0700 "$NB_STATE_DIR"; chmod 0600 "$ENV_FILE" 2>/dev/null || true
}

copy_unit(){
  src="$PACKAGE_ROOT/$1"; dst="$UNIT_DIR/$1"; [ -f "$src" ] || fail "Missing $src"
  if [ -L "$dst" ] || [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then rm -f "$dst"; cp "$src" "$dst"; chmod 0644 "$dst"; fi
}
ensure_units(){
  copy_unit netbird-install.service; copy_unit netbird-install.timer; systemctl daemon-reload
  systemctl enable netbird-install.service >/dev/null 2>&1 || true
  systemctl enable --now netbird-install.timer >/dev/null 2>&1 || true
}
ensure_boot_hook(){
  if systemctl cat udm-boot.service >/dev/null 2>&1; then mkdir -p "$(dirname "$BOOT_HOOK")"; cp "$PACKAGE_ROOT/on-boot.sh" "$BOOT_HOOK"; chmod 0755 "$BOOT_HOOK"; fi
}

filter_netbird_environment(){
  input="$1"; output="$2"
  : >"$output"
  [ -f "$input" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$MARKER_BEGIN"|"$MARKER_END"|"$LEGACY_MARKER"|NB_STATE_DIR=*|NB_MANAGEMENT_URL=*|NB_DISABLE_EBPF_WG_PROXY=*|NB_USE_LEGACY_ROUTING=*|NB_DISABLE_CUSTOM_ROUTING=*) ;;
      *) printf '%s\n' "$line" >>"$output";;
    esac
  done <"$input"
}

sync_netbird_environment(){
  mkdir -p "$(dirname "$SYSCONFIG")"; touch "$SYSCONFIG"
  tmp="$SYSCONFIG.tmp.$$"
  filter_netbird_environment "$SYSCONFIG" "$tmp"
  {
    printf '%s\n' "$MARKER_BEGIN"
    write_config_value NB_STATE_DIR "$NB_STATE_DIR"
    write_config_value NB_MANAGEMENT_URL "$NB_MANAGEMENT_URL"
    write_config_value NB_DISABLE_EBPF_WG_PROXY "$NB_DISABLE_EBPF_WG_PROXY"
    if [ "$NETBIRD_ROUTING_MODE" = legacy ]; then write_config_value NB_USE_LEGACY_ROUTING true; fi
    printf '%s\n' "$MARKER_END"
  } >>"$tmp"
  chmod 0644 "$tmp"; mv -f "$tmp" "$SYSCONFIG"
}

remove_netbird_environment(){
  [ -f "$SYSCONFIG" ] || return 0
  tmp="$SYSCONFIG.tmp.$$"
  filter_netbird_environment "$SYSCONFIG" "$tmp"
  if grep -q '[^[:space:]]' "$tmp"; then chmod 0644 "$tmp"; mv -f "$tmp" "$SYSCONFIG"; else rm -f "$tmp" "$SYSCONFIG"; fi
}

ensure_repo(){
  mkdir -p "$(dirname "$APT_KEY")" "$(dirname "$APT_SOURCE")"
  if [ ! -f "$APT_KEY" ]; then t="$APT_KEY.tmp.$$"; curl -fsSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor >"$t"; chmod 0644 "$t"; mv -f "$t" "$APT_KEY"; fi
  want="deb [signed-by=$APT_KEY] https://pkgs.netbird.io/debian stable main"
  if [ "$(cat "$APT_SOURCE" 2>/dev/null || true)" != "$want" ]; then printf '%s\n' "$want" >"$APT_SOURCE"; chmod 0644 "$APT_SOURCE"; fi
}
netbird_installed(){ dpkg-query -W -f='${Status}' netbird 2>/dev/null | grep -q '^install ok installed$'; }

ensure_package(){
  mode="$1"; ensure_repo
  if ! netbird_installed || ! has netbird; then
    apt-get update
    if netbird_installed; then apt-get install --reinstall -y netbird; else apt-get install -y netbird; fi
    return
  fi
  if [ "$mode" != update ]; then
    if [ "$mode" != auto ] || [ "$NETBIRD_AUTOUPDATE" != true ]; then return 0; fi
  fi
  if apt-get update; then
    if ! apt-get install -y netbird; then
      log "NetBird update failed; retaining installed package"; systemctl start netbird.service >/dev/null 2>&1 || true
      if [ "$mode" != auto ]; then return 1; fi
    fi
  else
    log "Unable to refresh NetBird apt metadata; retaining installed package"
    if [ "$mode" != auto ]; then return 1; fi
  fi
}

ensure_service(){
  if ! systemctl cat netbird.service >/dev/null 2>&1; then netbird service install || true; systemctl daemon-reload; fi
  systemctl enable netbird.service >/dev/null 2>&1 || true; systemctl start netbird.service
}

port_notice(){
  old="$(cat "$PORT_FILE" 2>/dev/null || true)"
  if [ -n "$old" ] && [ "$old" != "$NB_WIREGUARD_PORT" ]; then
    printf 'WireGuard port changed:\n    old: UDP/%s\n    new: UDP/%s\n\nNetBird normally requires no inbound WAN rule.\nIf you intentionally maintain a static port mapping, update it to UDP/%s.\n' "$old" "$NB_WIREGUARD_PORT" "$NB_WIREGUARD_PORT"
  fi
}

netbird_up(){
  set -- --management-url "$NB_MANAGEMENT_URL" --hostname "$NB_HOSTNAME" --interface-name "$NB_INTERFACE_NAME" --wireguard-port "$NB_WIREGUARD_PORT" "$@"
  if [ "$NETBIRD_DNS_MODE" = unmanaged ]; then set -- --disable-dns "$@"; else set -- --disable-dns=false "$@"; fi
  port_notice; netbird up "$@"
  printf '%s\n' "$NB_WIREGUARD_PORT" >"$PORT_FILE"; chmod 0600 "$PORT_FILE"
}

show_summary(){
  v="$(netbird version 2>/dev/null | head -n1 || printf unknown)"
  printf 'NetBird\n  Version:          %s\n  Management:       %s\n  Interface:        %s\n  WireGuard port:   UDP/%s\n  State directory:  %s\n  DNS mode:         %s\n  Routing mode:     %s\n\nConnectivity\n  NetBird normally requires no inbound WAN firewall rule, including\n  when this peer routes a Network. UniFi firewall policy is unchanged.\n' "$v" "$NB_MANAGEMENT_URL" "$NB_INTERFACE_NAME" "$NB_WIREGUARD_PORT" "$NB_STATE_DIR" "$NETBIRD_DNS_MODE" "$NETBIRD_ROUTING_MODE"
}
