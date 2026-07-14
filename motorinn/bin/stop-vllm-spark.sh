#!/bin/bash
set -euo pipefail

# Approval gate: require explicit environment variable to allow runtime stop
if [ "${ALLOW_RUNTIME_STOP:-}" != "1" ]; then
  echo "approval_required=ALLOW_RUNTIME_STOP"
  exit 1
fi

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Stop containers on HEAD_HOST
run_remote "$HEAD_HOST" "docker rm -f vllm-spark-head vllm-dspark-head vllm-head" || true

# Stop containers on WORKER_HOST
run_remote "$WORKER_HOST" "docker rm -f vllm-spark-worker vllm-dspark-worker vllm-worker" || true

# Stop Ray on both hosts
run_remote "$HEAD_HOST" "ray stop --force"
run_remote "$WORKER_HOST" "ray stop --force"

echo "runtime_stopped=true"
