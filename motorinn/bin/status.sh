#!/usr/bin/env bash
# status.sh - Read-only summary of cluster status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Call preflight.sh --check-only to get machine-readable result
# It must not merely echo configuration.
exec "${SCRIPT_DIR}/preflight.sh" --check-only
