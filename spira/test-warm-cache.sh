#!/usr/bin/env bash
# covers: scripts/warm-cache.sh, scripts/check-warm-fresh.sh
# Delegates to the actual suite in scripts/; the harness runs suites from spira/.
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-warm-cache.sh" "$@"
