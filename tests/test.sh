#!/bin/sh
set -eu

for file in install.sh package/manage.sh package/common.sh package/on-boot.sh; do sh -n "$file"; done
contains(){ grep -F -- "$2" "$1" >/dev/null || { echo "expected $1 to contain: $2" >&2; exit 1; }; }
not_contains(){ if grep -F -- "$2" "$1" >/dev/null; then echo "expected $1 not to contain: $2" >&2; exit 1; fi; }

contains package/netbird-env 'NB_STATE_DIR="/data/netbird/state"'
contains package/netbird-env 'NB_WIREGUARD_PORT="41642"'
contains package/netbird-env 'NETBIRD_DNS_MODE="unmanaged"'
contains package/netbird-env 'NETBIRD_CLIENT_ROUTES="disabled"'
contains package/netbird-env 'NETBIRD_ROUTING_MODE="auto"'
contains package/netbird-env 'NETBIRD_AUTOUPDATE="false"'

contains package/common.sh 'NETBIRD_ROOT="/data/netbird"'
contains package/common.sh '[ "$NB_STATE_DIR" = /data/netbird/state ]'
contains package/common.sh 'Refusing to source symlinked $ENV_FILE'
contains package/common.sh '# BEGIN netbird-unifi managed environment'
contains package/common.sh '# END netbird-unifi managed environment'
contains package/common.sh "printf '%s=\"%s\"\\n'"
contains package/common.sh 'NB_USE_LEGACY_ROUTING=true'
not_contains package/common.sh 'NB_DISABLE_CUSTOM_ROUTING=true'
contains package/common.sh 'apt-get install -y netbird'
contains package/common.sh 'apt-get install --reinstall -y netbird'
not_contains package/common.sh '/usr/local/bin/netbird'
not_contains package/common.sh 'netbird.previous'
contains package/common.sh 'SYSCONFIG="${SYSCONFIG_FILE:-/etc/sysconfig/netbird}"'
contains package/common.sh '--wireguard-port "$NB_WIREGUARD_PORT"'
contains package/common.sh '--interface-name "$NB_INTERFACE_NAME"'
contains package/common.sh '--hostname "$NB_HOSTNAME"'
contains package/common.sh 'set -- --disable-dns "$@"'
contains package/common.sh 'set -- --disable-client-routes "$@"'
contains package/common.sh 'set -- --disable-client-routes=false "$@"'
contains package/common.sh 'NetBird normally requires no inbound WAN firewall rule'
not_contains package/common.sh 'Internet Local → UDP/%s → Accept'
not_contains package/common.sh 'case "$MODEL"'

contains package/manage.sh 'preflight_cleanup; acquire_lock'
contains package/manage.sh 'NetBird package removal failed.'
contains package/manage.sh 'remove_netbird_environment'
contains package/manage.sh "[ \"\$answer\" = 'PURGE /data/netbird' ]"
contains package/manage.sh 'rm -rf -- /data/netbird'
contains package/manage.sh 'Known routing/firewall compatibility symptoms were detected.'
contains package/common.sh '[ -L "$dst" ]'
contains package/netbird-install.service 'RequiresMountsFor=/data/netbird'
contains package/netbird-install.service 'Environment=DEBIAN_FRONTEND=noninteractive'
contains package/netbird-install.service 'RestartSec=5m'

contains build/package.sh 'common.sh'
contains build/package.sh 'cp "$SOURCE/LICENSE" "$WORKDIR/netbird/LICENSE"'
contains build/package.sh 'sha256sum netbird-unifi.tgz'
contains install.sh 'ROOT="/data/netbird"'
contains install.sh 'NETBIRD_ROOT is not supported'
contains install.sh 'Refusing to use symlinked $ROOT/netbird-env'
contains install.sh 'sha256sum -c netbird-unifi.tgz.sha256'
contains install.sh 'install -m 0644 "$tmp/netbird/LICENSE" "$ROOT/LICENSE"'
contains install.sh 'install -m 0644 "$tmp/netbird/common.sh" "$ROOT/common.sh"'

# Interactive first-install UX remains optional and curl|sh-safe via /dev/tty.
contains install.sh 'NETBIRD_UNIFI_NONINTERACTIVE'
contains install.sh 'Configure this NetBird peer.'
contains install.sh 'NetBird hostname'
contains install.sh 'Management URL'
contains install.sh 'WireGuard UDP port'
contains install.sh 'DNS mode (managed/unmanaged)'
contains install.sh 'Accept remote NetBird Network routes on this gateway?'
contains install.sh 'Client routes:'
contains install.sh 'Routing mode (auto/legacy)'
contains install.sh 'Automatically update NetBird from the official apt repository?'
contains install.sh 'Continue with this configuration?'
contains install.sh '</dev/tty'

for key in NB_STATE_DIR NB_HOSTNAME NB_MANAGEMENT_URL NB_INTERFACE_NAME NB_WIREGUARD_PORT NB_DISABLE_EBPF_WG_PROXY NETBIRD_DNS_MODE NETBIRD_CLIENT_ROUTES NETBIRD_ROUTING_MODE NETBIRD_AUTOUPDATE; do
  contains install.sh "set_config_value \"\$ROOT/netbird-env\" $key"
done

contains .github/workflows/release.yml "tags: ['v[0-9]*']"
contains .github/workflows/release.yml '--draft --verify-tag --generate-notes'
not_contains .github/workflows/release.yml 'types: [published]'
contains LICENSE 'Copyright © 2022 Sierra Softworks'

echo "syntax and lifecycle contract tests OK"
