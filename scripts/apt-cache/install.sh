#!/usr/bin/env bash
# Installs and configures apt-cacher-ng, the LAN apt cache the runner images
# auto-detect (the detect hook embedded in scripts/template-substrate.sh). Run as root on the host that serves it.
#
#   sudo bash scripts/apt-cache/install.sh          # install + start on :3142
#   bash scripts/apt-cache/check.sh http://HOST:3142
#
# The cache must be reachable from the tailnet for EC2 spill instances to use it;
# when it is not, runners fall back to DIRECT and nothing breaks.
set -euo pipefail

PORT="${APT_CACHE_PORT:-3142}"
CONF=/etc/apt-cacher-ng/zz-ephemeral-ci.conf

[ "$(id -u)" -eq 0 ] || { echo "install.sh: run as root" >&2; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get install -y apt-cacher-ng curl

cat > "$CONF" <<CONFIG
# managed by ephemeral-ci scripts/apt-cache/install.sh
Port: ${PORT}
BindAddress: 0.0.0.0
PassThroughPattern: .*
CONFIG

systemctl enable apt-cacher-ng
systemctl restart apt-cacher-ng
echo "apt-cacher-ng listening on :${PORT}; verify with scripts/apt-cache/check.sh"
