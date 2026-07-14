#!/bin/bash
set -euo pipefail

# Reject positional arguments
if [ $# -gt 0 ]; then
  echo "error: no positional arguments allowed"
  exit 1
fi

# Approval gate: require explicit environment variable to allow runtime stop
if [ "${ALLOW_RUNTIME_STOP:-}" != "1" ]; then
  echo "approval_required=ALLOW_RUNTIME_STOP"
  exit 1
fi

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Aggregate failures while still addressing both hosts.
stop_failed=0
HEAD_REMOVE_COMMAND='command -v docker >/dev/null 2>&1 || exit 2; failed=0; for container in vllm-spark-head vllm-dspark-head vllm-head; do if docker container inspect "$container" >/dev/null 2>&1; then docker rm -f "$container" || failed=1; fi; done; exit "$failed"'
WORKER_REMOVE_COMMAND='command -v docker >/dev/null 2>&1 || exit 2; failed=0; for container in vllm-spark-worker vllm-dspark-worker vllm-worker; do if docker container inspect "$container" >/dev/null 2>&1; then docker rm -f "$container" || failed=1; fi; done; exit "$failed"'

run_control() {
  local host="$1"
  local command="$2"
  local rc
  set +e
  run_remote "$host" "$command"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    stop_failed=1
  fi
}

run_control "$HEAD_HOST" "$HEAD_REMOVE_COMMAND"
run_control "$WORKER_HOST" "$WORKER_REMOVE_COMMAND"
run_control "$HEAD_HOST" "ray stop --force"
run_control "$WORKER_HOST" "ray stop --force"

if [ $stop_failed -eq 0 ]; then
  echo "runtime_stopped=true"
else
  echo "runtime_stop_partial_failure"
  exit 1
fi
