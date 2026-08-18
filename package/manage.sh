#!/bin/sh
set -eu

PACKAGE_ROOT="${PACKAGE_ROOT:-$(dirname -- "$(readlink -f -- "$0")")}" 
# shellcheck source=package/common.sh
# shellcheck disable=SC1091
. "$PACKAGE_ROOT/common.sh"

cmd_install(){
  preflight_package; acquire_lock
  ensure_state; ensure_units; sync_netbird_environment; ensure_package install; sync_netbird_environment; ensure_service; ensure_boot_hook
  release_lock; show_summary
}

cmd_maintain(){
  preflight_package; acquire_lock
  # Repair persistence before network/package work, matching tailscale-unifi.
  ensure_units; ensure_state; sync_netbird_environment; ensure_package auto; sync_netbird_environment; ensure_service; ensure_boot_hook
  release_lock
}

cmd_update(){ preflight_package; acquire_lock; ensure_state; sync_netbird_environment; ensure_package update; sync_netbird_environment; ensure_service; release_lock; }

cmd_apply(){
  preflight_runtime; acquire_lock; ensure_state; sync_netbird_environment
  if netbird_installed; then systemctl restart netbird.service; fi
  port_notice; release_lock
  log "Daemon environment applied. Run '$NETBIRD_ROOT/manage.sh up' for peer defaults."
}

cmd_up(){
  preflight_runtime; acquire_lock; ensure_state; sync_netbird_environment
  netbird_installed || fail "NetBird is not installed"
  ensure_service; netbird_up "$@"; release_lock
}

cmd_down(){ preflight_runtime; netbird down "$@"; }
cmd_restart(){ preflight_runtime; systemctl restart netbird.service; }

cmd_status(){
  preflight; show_summary; log ""; log "Effective NetBird status"
  if netbird_installed; then netbird status -d "$@" || true; else log "NetBird package is not installed"; fi
}

cmd_diagnose(){
  preflight; show_summary; log ""
  if has ubnt-device-info; then
    log "UniFi device: $(ubnt-device-info model 2>/dev/null || printf unknown)"
    log "UniFi firmware: $(ubnt-device-info firmware_detail 2>/dev/null || printf unknown)"
  fi
  if [ -c /dev/net/tun ]; then log "TUN: available"; else log "TUN: MISSING"; fi
  if has ss && ss -lun 2>/dev/null | grep -q ":${NB_WIREGUARD_PORT}[[:space:]]"; then log "UDP/$NB_WIREGUARD_PORT: listening"; else log "UDP/$NB_WIREGUARD_PORT: not observed listening"; fi
  if systemctl is-active --quiet netbird.service; then log "Service: active"; else log "Service: not active"; fi
  if has journalctl && journalctl -u netbird.service -n 200 --no-pager 2>/dev/null | grep -Eq 'NETBIRD-RT-FWD-IN|Chain already exists|fwmark|invalid argument'; then
    log "Known routing/firewall compatibility symptoms were detected."
    log "Consider NETBIRD_ROUTING_MODE=\"legacy\", then run manage.sh apply and manage.sh up."
  fi
}

cmd_uninstall(){
  preflight_cleanup; acquire_lock
  package_installed=false
  if netbird_installed; then need apt-get; package_installed=true; fi
  if has netbird; then netbird down >/dev/null 2>&1 || true; fi
  systemctl disable --now netbird-install.timer >/dev/null 2>&1 || true
  systemctl disable netbird-install.service >/dev/null 2>&1 || true
  systemctl disable --now netbird.service >/dev/null 2>&1 || true
  rm -f "$BOOT_HOOK"
  if [ "$package_installed" = true ] && ! apt-get remove -y netbird; then
    release_lock
    fail "NetBird package removal failed. Package support files were preserved so uninstall can be retried; check service and timer state."
  fi
  remove_netbird_environment
  rm -f "$UNIT_DIR/netbird-install.service" "$UNIT_DIR/netbird-install.timer" "$APT_SOURCE" "$APT_KEY" "$PORT_FILE"
  systemctl daemon-reload; release_lock
  log "NetBird removed; $ENV_FILE and /data/netbird/state were preserved."
}

cmd_purge(){
  preflight_cleanup; validate_purge_target "$NETBIRD_ROOT"
  printf 'Type PURGE /data/netbird to permanently delete config and peer identity: '; read -r answer
  [ "$answer" = 'PURGE /data/netbird' ] || fail "Purge cancelled"
  cmd_uninstall
  validate_purge_target "$NETBIRD_ROOT"
  rm -rf -- /data/netbird
  log "NetBird config and peer identity purged."
}

usage(){ printf 'Usage: %s {install|maintain|on-boot|update|apply|up|down|status|diagnose|restart|uninstall|purge}\n' "$0"; }
command="${1:-}"; [ $# -eq 0 ] || shift
case "$command" in
  install) cmd_install "$@";; maintain|on-boot) cmd_maintain "$@";; update) cmd_update "$@";; apply) cmd_apply "$@";;
  up) cmd_up "$@";; down) cmd_down "$@";; status) cmd_status "$@";; diagnose) cmd_diagnose "$@";; restart) cmd_restart "$@";;
  uninstall) cmd_uninstall "$@";; purge) cmd_purge "$@";; help|-h|--help|'') usage;; *) usage >&2; exit 2;;
esac
