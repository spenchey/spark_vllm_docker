#!/bin/bash
set -euo pipefail

# Reject positional arguments
if [ $# -gt 0 ]; then
  echo "error: no positional arguments allowed"
  exit 1
fi

# Approval gate: require explicit environment variable to allow runtime start
if [ "${ALLOW_RUNTIME_START:-}" != "1" ]; then
  echo "approval_required=ALLOW_RUNTIME_START"
  exit 1
fi

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Run preflight check
set +e
preflight_output=$("${SCRIPT_DIR}/preflight.sh" --check-only 2>&1)
preflight_exit=$?
set -e

if [ $preflight_exit -ne 0 ]; then
  echo "preflight_check_failed"
  exit 1
fi

# Check if start is allowed
if ! echo "$preflight_output" | grep -q "^start_allowed=true$"; then
  echo "start_not_allowed"
  exit 1
fi

# Handle media block flag
if echo "$preflight_output" | grep -q "^blocked_media_in_use=true$"; then
  if [ "${ALLOW_MEDIA_STOP:-}" != "1" ]; then
    echo "media_blocked_no_allow"
    exit 1
  fi
fi

# Health check configuration
HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-600}
HEALTH_POLL_SECONDS=${HEALTH_POLL_SECONDS:-5}

# Validate health settings as positive integers
if ! [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEALTH_TIMEOUT_SECONDS" -le 0 ] 2>/dev/null; then
  echo "invalid_health_timeout"
  exit 1
fi
if ! [[ "$HEALTH_POLL_SECONDS" =~ ^[0-9]+$ ]] || [ "$HEALTH_POLL_SECONDS" -le 0 ] 2>/dev/null; then
  echo "invalid_health_poll"
  exit 1
fi

# Start worker first via remote
run_remote "$WORKER_HOST" "cd ${RELEASE_PATH} && docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile worker up -d worker"

# Wait for worker to initialize
sleep 25

# Start head via remote
run_remote "$HEAD_HOST" "cd $RELEASE_PATH && docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile head up -d head"

# Calculate deadline using SECONDS
start_time=$SECONDS
deadline=$((start_time + HEALTH_TIMEOUT_SECONDS))

while true; do
  current_time=$SECONDS
  if [ $current_time -ge $deadline ]; then
    echo "health_check_timeout"
    # Show logs for the two specific containers on their respective hosts
    run_remote "$WORKER_HOST" "docker logs --tail 200 vllm-spark-worker" || true
    run_remote "$HEAD_HOST" "docker logs --tail 200 vllm-spark-head" || true
    exit 1
  fi

  # Poll health via remote curl
  set +e
  health_output=$(run_remote "$HEAD_HOST" "curl -fsS --max-time 5 http://127.0.0.1:8000/health" 2>&1)
  health_exit=$?
  set -e

  if [ $health_exit -eq 0 ]; then
    echo "runtime_started=true"
    exit 0
  fi

  remaining=$((deadline - SECONDS))
  if [ $remaining -le 0 ]; then
    continue
  fi
  sleep_for="$HEALTH_POLL_SECONDS"
  if [ "$sleep_for" -gt "$remaining" ]; then
    sleep_for="$remaining"
  fi
  sleep "$sleep_for"
done
