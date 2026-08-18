#!/bin/sh
set -eu

REPO="${NETBIRD_UNIFI_REPO:-djrarky/netbird-unifi}"
VERSION="${NETBIRD_UNIFI_VERSION:-latest}"
ROOT="/data/netbird"
NONINTERACTIVE="${NETBIRD_UNIFI_NONINTERACTIVE:-false}"

fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
case "${NETBIRD_ROOT:-}" in ''|/data/netbird) :;; *) fail "NETBIRD_ROOT is not supported; netbird-unifi uses /data/netbird";; esac
[ "$(id -u)" -eq 0 ] || fail "Run this installer as root"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

if command -v ubnt-device-info >/dev/null 2>&1; then
  printf 'Detected: %s (%s)\n' "$(ubnt-device-info model 2>/dev/null || true)" "$(ubnt-device-info firmware 2>/dev/null || true)"
else
  printf 'WARNING: ubnt-device-info not found; this installer is intended for UniFi OS gateways.\n' >&2
fi

interactive=false
if [ "$NONINTERACTIVE" != true ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then interactive=true; fi

ask_value(){
  label="$1"; default="$2"
  printf '%s [%s]: ' "$label" "$default" >/dev/tty
  IFS= read -r answer </dev/tty || answer=""
  [ -n "$answer" ] || answer="$default"
  printf '%s\n' "$answer"
}

ask_choice(){
  label="$1"; default="$2"; allowed="$3"
  while :; do
    value="$(ask_value "$label" "$default")"
    case " $allowed " in *" $value "*) printf '%s\n' "$value"; return 0;; esac
    printf 'Please choose one of: %s\n' "$allowed" >/dev/tty
  done
}

ask_yes_no(){
  label="$1"; default="$2"
  while :; do
    if [ "$default" = true ]; then hint='Y/n'; else hint='y/N'; fi
    printf '%s [%s]: ' "$label" "$hint" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
      '') printf '%s\n' "$default"; return 0;;
      y|Y|yes|YES|Yes) printf '%s\n' true; return 0;;
      n|N|no|NO|No) printf '%s\n' false; return 0;;
      *) printf 'Please answer yes or no.\n' >/dev/tty;;
    esac
  done
}

if [ "$VERSION" = latest ]; then URL="https://github.com/$REPO/releases/latest/download/netbird-unifi.tgz"; else URL="https://github.com/$REPO/releases/download/$VERSION/netbird-unifi.tgz"; fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT TERM
printf 'Downloading netbird-unifi package...\n'
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/netbird-unifi.tgz" "$URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/netbird-unifi.tgz.sha256" "$URL.sha256"
(cd "$tmp" && sha256sum -c netbird-unifi.tgz.sha256)
tar xzf "$tmp/netbird-unifi.tgz" -C "$tmp"
if [ ! -f "$tmp/netbird/manage.sh" ] || [ ! -f "$tmp/netbird/common.sh" ] || [ ! -f "$tmp/netbird/LICENSE" ]; then fail "Invalid netbird-unifi package"; fi

# Reuse the package's validated literal writer for first-install configuration.
unset NETBIRD_UNIFI_TESTING ENV_FILE SYSTEMD_UNIT_DIR SYSCONFIG_FILE APT_SOURCE APT_KEY \
  PORT_FILE LOCK_DIR BOOT_HOOK_FILE PACKAGE_ROOT 2>/dev/null || true
# shellcheck source=package/common.sh
# shellcheck disable=SC1091
. "$tmp/netbird/common.sh"

[ ! -L "$ROOT" ] || fail "Refusing to install through symlinked $ROOT"
mkdir -p "$ROOT"
install -m 0755 "$tmp/netbird/manage.sh" "$ROOT/manage.sh"
install -m 0644 "$tmp/netbird/common.sh" "$ROOT/common.sh"
install -m 0644 "$tmp/netbird/netbird-install.service" "$ROOT/netbird-install.service"
install -m 0644 "$tmp/netbird/netbird-install.timer" "$ROOT/netbird-install.timer"
install -m 0755 "$tmp/netbird/on-boot.sh" "$ROOT/on-boot.sh"
install -m 0644 "$tmp/netbird/netbird-env" "$ROOT/netbird-env.dist"
install -m 0644 "$tmp/netbird/LICENSE" "$ROOT/LICENSE"

[ ! -L "$ROOT/netbird-env" ] || fail "Refusing to use symlinked $ROOT/netbird-env"
if [ ! -f "$ROOT/netbird-env" ]; then
  NB_STATE_DIR="${NB_STATE_DIR:-/data/netbird/state}"
  NB_DISABLE_EBPF_WG_PROXY="${NB_DISABLE_EBPF_WG_PROXY:-true}"
  default_hostname="${NB_HOSTNAME:-$(hostname 2>/dev/null || printf netbird-unifi)}"
  default_management="${NB_MANAGEMENT_URL:-https://api.netbird.io:443}"
  default_interface="${NB_INTERFACE_NAME:-netbird0}"
  default_port="${NB_WIREGUARD_PORT:-41642}"
  default_dns="${NETBIRD_DNS_MODE:-unmanaged}"
  default_routing="${NETBIRD_ROUTING_MODE:-auto}"
  default_update="${NETBIRD_AUTOUPDATE:-false}"

  if [ "$interactive" = true ]; then
    printf '\nConfigure this NetBird peer. Press Enter to accept a default.\n\n' >/dev/tty
    NB_HOSTNAME="$(ask_value 'NetBird hostname' "$default_hostname")"
    NB_MANAGEMENT_URL="$(ask_value 'Management URL' "$default_management")"
    NB_INTERFACE_NAME="$(ask_value 'Interface name' "$default_interface")"
    NB_WIREGUARD_PORT="$(ask_value 'WireGuard UDP port' "$default_port")"
    NETBIRD_DNS_MODE="$(ask_choice 'DNS mode (managed/unmanaged)' "$default_dns" 'managed unmanaged')"
    NETBIRD_ROUTING_MODE="$(ask_choice 'Routing mode (auto/legacy)' "$default_routing" 'auto legacy')"
    NETBIRD_AUTOUPDATE="$(ask_yes_no 'Automatically update NetBird from the official apt repository?' "$default_update")"

    printf '\nConfiguration summary\n' >/dev/tty
    printf '  Hostname:         %s\n' "$NB_HOSTNAME" >/dev/tty
    printf '  Management URL:   %s\n' "$NB_MANAGEMENT_URL" >/dev/tty
    printf '  Interface:        %s\n' "$NB_INTERFACE_NAME" >/dev/tty
    printf '  WireGuard port:   UDP/%s\n' "$NB_WIREGUARD_PORT" >/dev/tty
    printf '  DNS mode:         %s\n' "$NETBIRD_DNS_MODE" >/dev/tty
    printf '  Routing mode:     %s\n' "$NETBIRD_ROUTING_MODE" >/dev/tty
    printf '  Automatic update: %s\n\n' "$NETBIRD_AUTOUPDATE" >/dev/tty
    confirmed="$(ask_yes_no 'Continue with this configuration?' true)"
    [ "$confirmed" = true ] || fail "Installation cancelled"
  else
    NB_HOSTNAME="$default_hostname"
    NB_MANAGEMENT_URL="$default_management"
    NB_INTERFACE_NAME="$default_interface"
    NB_WIREGUARD_PORT="$default_port"
    NETBIRD_DNS_MODE="$default_dns"
    NETBIRD_ROUTING_MODE="$default_routing"
    NETBIRD_AUTOUPDATE="$default_update"
  fi

  validate_env
  install -m 0600 "$tmp/netbird/netbird-env" "$ROOT/netbird-env"
  set_config_value "$ROOT/netbird-env" NB_STATE_DIR "$NB_STATE_DIR"
  set_config_value "$ROOT/netbird-env" NB_HOSTNAME "$NB_HOSTNAME"
  set_config_value "$ROOT/netbird-env" NB_MANAGEMENT_URL "$NB_MANAGEMENT_URL"
  set_config_value "$ROOT/netbird-env" NB_INTERFACE_NAME "$NB_INTERFACE_NAME"
  set_config_value "$ROOT/netbird-env" NB_WIREGUARD_PORT "$NB_WIREGUARD_PORT"
  set_config_value "$ROOT/netbird-env" NB_DISABLE_EBPF_WG_PROXY "$NB_DISABLE_EBPF_WG_PROXY"
  set_config_value "$ROOT/netbird-env" NETBIRD_DNS_MODE "$NETBIRD_DNS_MODE"
  set_config_value "$ROOT/netbird-env" NETBIRD_ROUTING_MODE "$NETBIRD_ROUTING_MODE"
  set_config_value "$ROOT/netbird-env" NETBIRD_AUTOUPDATE "$NETBIRD_AUTOUPDATE"
else
  printf 'Preserving existing configuration: %s/netbird-env\n' "$ROOT"
fi

"$ROOT/manage.sh" install

printf '\nInstallation complete.\n'
printf 'Review configuration: %s/netbird-env\n' "$ROOT"
printf 'Enroll/connect with: %s/manage.sh up [NetBird up arguments]\n' "$ROOT"
printf 'For setup-key enrolment, prefer --setup-key-file so the key is not stored in shell history.\n'
