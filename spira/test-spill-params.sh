#!/usr/bin/env bash
# covers: scripts/spill-params.sh, scripts/ec2-diag.sh, scripts/check-spill-permissions.sh
# Delegates to the actual suite in scripts/; the harness runs suites from spira/.
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-spill-params.sh" "$@"
