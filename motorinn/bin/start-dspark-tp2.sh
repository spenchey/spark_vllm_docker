#!/bin/bash
set -euo pipefail

# Approval gate: require explicit environment variable to allow runtime start
if [ "${ALLOW_RUNTIME_START:-}" != "1" ]; then
  echo "approval_required=ALLOW_RUNTIME_START"
  exit 1
fi

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Run preflight check
# Capture output to inspect flags
preflight_output=$("${SCRIPT_DIR}/preflight.sh" --check-only 2>&1 || true)
preflight_exit=$?

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

# Start worker first
cd "$RELEASE_PATH"
docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile worker up -d worker

# Wait for worker to initialize
sleep 25

# Start head
docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile head up -d head

# Health check configuration
HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-600}
HEALTH_POLL_SECONDS=${HEALTH_POLL_SECONDS:-5}

# Calculate deadline using SECONDS
start_time=$SECONDS
deadline=$((start_time + HEALTH_TIMEOUT_SECONDS))

while true; do
  current_time=$SECONDS
  if [ $current_time -ge $deadline ]; then
    echo "health_check_timeout"
    # Show logs for the two specific containers on their respective hosts
    run_remote "$WORKER_HOST" "docker logs --tail 200 vllm-spark-worker"
    run_remote "$HEAD_HOST" "docker logs --tail 200 vllm-spark-head"
    exit 1
  fi

  # Poll health via remote curl
  health_output=$(run_remote "$HEAD_HOST" "curl -fsS --max-time 5 http://127.0.0.1:8000/health" 2>&1 || true)
  if [ $? -eq 0 ] && echo "$health_output" | grep -q "ok"; then
    echo "runtime_started=true"
    exit 0
  fi

  sleep $HEALTH_POLL_SECONDS
done
