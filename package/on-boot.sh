#!/bin/sh
set -eu

# Optional secondary persistence hook for systems already using unifi-common/udm-boot.
# The primary persistence mechanism is netbird-install.service + timer.
exec /data/netbird/manage.sh maintain
