#!/usr/bin/env bash
# covers: .github/workflows/advance-v1.yml
# Delegates to the actual suite in scripts/; the harness runs suites from spira/.
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-advance-credentials.sh" "$@"
