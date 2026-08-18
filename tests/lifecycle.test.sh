#!/bin/sh
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data/netbird" "$TMP/etc/systemd" "$TMP/etc/sysconfig" "$TMP/apt" "$TMP/key" "$TMP/on_boot.d"

cat >"$TMP/data/netbird/netbird-env" <<'EOF'
NB_STATE_DIR="/data/netbird/state"
NB_HOSTNAME="test-router"
NB_MANAGEMENT_URL="https://netbird.example.test:443"
NB_INTERFACE_NAME="netbird0"
NB_WIREGUARD_PORT="41642"
NB_DISABLE_EBPF_WG_PROXY="true"
NETBIRD_DNS_MODE="unmanaged"
NETBIRD_ROUTING_MODE="auto"
NETBIRD_AUTOUPDATE="false"
EOF

export NETBIRD_UNIFI_TESTING=true
export ENV_FILE="$TMP/data/netbird/netbird-env"
export SYSTEMD_UNIT_DIR="$TMP/etc/systemd"
export SYSCONFIG_FILE="$TMP/etc/sysconfig/netbird"
export APT_SOURCE="$TMP/apt/netbird.list"
export APT_KEY="$TMP/key/netbird.gpg"
export PORT_FILE="$TMP/data/netbird/.applied-wireguard-port"
export LOCK_DIR="$TMP/data/netbird/.manage.lock"
export BOOT_HOOK_FILE="$TMP/on_boot.d/20-netbird.sh"
export PACKAGE_ROOT="$REPO_ROOT/package"
# shellcheck source=package/common.sh
. "$REPO_ROOT/package/common.sh"

assert(){ "$@" || { echo "assertion failed: $*" >&2; exit 1; }; }
reject(){ if ("$@") >/dev/null 2>&1; then echo "expected rejection: $*" >&2; exit 1; fi; }

# Synchronization removes only owned settings and preserves administrator lines,
# including lines after both the legacy marker and the new bounded block.
cat >"$SYSCONFIG" <<'EOF'
BEFORE="keep"
# netbird-unifi managed environment
NB_STATE_DIR="old"
AFTER_LEGACY="keep"
# BEGIN netbird-unifi managed environment
NB_MANAGEMENT_URL="old"
INSIDE_BLOCK="also-keep"
# END netbird-unifi managed environment
AFTER_NEW="keep"
EOF
load_env; validate_env; sync_netbird_environment
first="$(cat "$SYSCONFIG")"
sync_netbird_environment
assert test "$first" = "$(cat "$SYSCONFIG")"
for name in BEFORE AFTER_LEGACY INSIDE_BLOCK AFTER_NEW; do assert grep -q "^${name}=\"keep\"\|^${name}=\"also-keep\"" "$SYSCONFIG"; done
assert grep -q '^NB_STATE_DIR="/data/netbird/state"$' "$SYSCONFIG"
assert grep -q '^NB_DISABLE_EBPF_WG_PROXY="true"$' "$SYSCONFIG"
assert test "$(grep -c '^# BEGIN netbird-unifi managed environment$' "$SYSCONFIG")" -eq 1
assert test "$(grep -c '^# END netbird-unifi managed environment$' "$SYSCONFIG")" -eq 1
assert test "$(grep -c '^NB_STATE_DIR=' "$SYSCONFIG")" -eq 1

# Legacy routing has one meaning. It does not silently disable broad/exit routes.
sed -i 's/NETBIRD_ROUTING_MODE="auto"/NETBIRD_ROUTING_MODE="legacy"/' "$ENV_FILE"
load_env; sync_netbird_environment
assert grep -q '^NB_USE_LEGACY_ROUTING="true"$' "$SYSCONFIG"
if grep -q '^NB_DISABLE_CUSTOM_ROUTING=' "$SYSCONFIG"; then echo "legacy mode disabled custom routing" >&2; exit 1; fi
sed -i 's/NETBIRD_ROUTING_MODE="legacy"/NETBIRD_ROUTING_MODE="auto"/' "$ENV_FILE"
load_env; sync_netbird_environment
if grep -q '^NB_USE_LEGACY_ROUTING=' "$SYSCONFIG"; then echo "legacy flag survived auto mode" >&2; exit 1; fi

# State and purge paths have exact, non-traversable boundaries.
for unsafe in / /data /data/.. /data/netbird /data/netbird/ /data/netbird/../etc /data/netbird/state/.. relative; do
  reject sh -c '. "$1"; load_env; NB_STATE_DIR="$2"; validate_env' sh "$REPO_ROOT/package/common.sh" "$unsafe"
done
for unsafe in / /data /data/.. /data/netbird/ /data/netbird/../etc relative; do
  reject validate_purge_root "$unsafe"
done
validate_purge_root /data/netbird
reject sh -c '. "$1"; load_env; NB_WIREGUARD_PORT=999999999999999999999999999999999999; validate_env' sh "$REPO_ROOT/package/common.sh"

# Generated configuration is a literal: shell-looking payloads do not execute.
literal_file="$TMP/literal-env"
printf 'VALUE=""\n' >"$literal_file"
sentinel="$TMP/serialization-executed"
payload="\$(touch $sentinel) \`touch $sentinel\` \"double\" 'single' \\ & |"
tmp="installer-temp-must-survive"
set_config_value "$literal_file" VALUE "$payload"
assert test "$tmp" = installer-temp-must-survive
actual="$(unset VALUE; . "$literal_file"; printf '%s' "$VALUE")"
assert test "$actual" = "$payload"
assert test ! -e "$sentinel"
multiline="$(printf 'one\ntwo')"
reject set_config_value "$literal_file" VALUE "$multiline"

# Old symlinked maintenance units are healed into regular files.
ln -s "$REPO_ROOT/package/netbird-install.service" "$SYSTEMD_UNIT_DIR/netbird-install.service"
copy_unit netbird-install.service
assert test -f "$SYSTEMD_UNIT_DIR/netbird-install.service"
assert test ! -L "$SYSTEMD_UNIT_DIR/netbird-install.service"
assert cmp -s "$REPO_ROOT/package/netbird-install.service" "$SYSTEMD_UNIT_DIR/netbird-install.service"

# Port changes mention optional mappings, without claiming an inbound rule is required.
printf '41642\n' >"$PORT_FILE"
NB_WIREGUARD_PORT=51821
notice="$(port_notice)"
case "$notice" in *'old: UDP/41642'*'new: UDP/51821'*'normally requires no inbound WAN rule'*'static port mapping'*) :;; *) echo "missing port notice" >&2; exit 1;; esac

# Auto-update network failure is non-fatal when an installed NetBird exists.
cat >"$TMP/bin/dpkg-query" <<'EOF'
#!/bin/sh
printf 'install ok installed'
EOF
cat >"$TMP/bin/netbird" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/apt-get" <<'EOF'
#!/bin/sh
[ "$1" != update ]
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$TMP/bin/gpg" <<'EOF'
#!/bin/sh
cat
EOF
chmod +x "$TMP/bin/"*
ORIGINAL_PATH="$PATH"
PATH="$TMP/bin:$PATH"; export PATH
printf 'key\n' >"$APT_KEY"
load_env; NETBIRD_AUTOUPDATE=true; ensure_package auto

# Uninstall ignores a malformed config, reports apt failure, and keeps the
# installed package's supporting repo/environment until a successful retry.
calls="$TMP/cleanup.calls"
export CLEANUP_CALLS="$calls"
cat >"$TMP/bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
exit 1
EOF
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$CLEANUP_CALLS"
exit 0
EOF
cat >"$TMP/bin/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >>"$CLEANUP_CALLS"
[ "${APT_REMOVE_FAIL:-false}" != true ]
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/systemctl" "$TMP/bin/apt-get"
printf 'BROKEN=$(touch %s)\n' "$TMP/config-executed" >"$ENV_FILE"
printf 'unit\n' >"$SYSTEMD_UNIT_DIR/netbird-install.service"
printf 'unit\n' >"$SYSTEMD_UNIT_DIR/netbird-install.timer"
printf 'repo\n' >"$APT_SOURCE"
printf 'key\n' >"$APT_KEY"
printf 'hook\n' >"$BOOT_HOOK"
printf '41642\n' >"$PORT_FILE"
cat >"$SYSCONFIG" <<'EOF'
ADMIN_BEFORE="keep"
# BEGIN netbird-unifi managed environment
NB_STATE_DIR='/data/netbird/state'
# END netbird-unifi managed environment
ADMIN_AFTER="keep"
EOF

if failure_output="$(APT_REMOVE_FAIL=true PATH="$TMP/bin:$ORIGINAL_PATH" sh "$REPO_ROOT/package/manage.sh" uninstall 2>&1)"; then
  echo "uninstall unexpectedly succeeded after apt failure" >&2; exit 1
fi
case "$failure_output" in *'NetBird package removal failed.'*) :;; *) echo "apt failure was not reported" >&2; exit 1;; esac
assert test ! -e "$TMP/config-executed"
assert test ! -e "$BOOT_HOOK"
assert test -f "$SYSTEMD_UNIT_DIR/netbird-install.service"
assert test -f "$APT_SOURCE"
assert grep -q '^NB_STATE_DIR=' "$SYSCONFIG"

PATH="$TMP/bin:$ORIGINAL_PATH" sh "$REPO_ROOT/package/manage.sh" uninstall >/dev/null
assert test -f "$ENV_FILE"
assert test ! -e "$SYSTEMD_UNIT_DIR/netbird-install.service"
assert test ! -e "$SYSTEMD_UNIT_DIR/netbird-install.timer"
assert test ! -e "$APT_SOURCE"
assert test ! -e "$APT_KEY"
assert grep -q '^ADMIN_BEFORE="keep"$' "$SYSCONFIG"
assert grep -q '^ADMIN_AFTER="keep"$' "$SYSCONFIG"
if grep -q 'netbird-unifi managed environment\|^NB_STATE_DIR=' "$SYSCONFIG"; then echo "managed sysconfig content survived uninstall" >&2; exit 1; fi
assert grep -q '^systemctl daemon-reload$' "$calls"

echo "mocked lifecycle tests OK"
