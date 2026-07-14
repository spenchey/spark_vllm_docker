#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

ENV_FILE="${REPO_ROOT}/motorinn/env/deepseek-v4-flash-dspark-tp2.env"
REMOTE_ENV_FILE="${REMOTE_REPO}/motorinn/env/deepseek-v4-flash-dspark-tp2.env"
"${REPO_ROOT}/motorinn/bin/preflight.sh" "${ENV_FILE}"

echo "Verifying DSpark model cache on both Sparks..."
ssh_head "'${REMOTE_REPO}/motorinn/bin/verify-dspark-model-cache.sh' '${MODEL_PATH:-/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark}'"
ssh_worker "'${REMOTE_REPO}/motorinn/bin/verify-dspark-model-cache.sh' '${MODEL_PATH:-/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark}'"

echo "Starting DSpark worker..."
ssh_worker "cd '${REMOTE_REPO}' && docker compose --env-file '${REMOTE_ENV_FILE}' -f docker-compose.yml -f compose/docker-compose.dspark-experiment.yml --profile worker up -d"
sleep 25
echo "Starting DSpark head..."
ssh_head "cd '${REMOTE_REPO}' && docker compose --env-file '${REMOTE_ENV_FILE}' -f docker-compose.yml -f compose/docker-compose.dspark-experiment.yml --profile head up -d"

echo "Waiting for health..."
for i in $(seq 1 180); do
  if ssh_head "curl -fsS --max-time 3 http://127.0.0.1:8000/health >/dev/null"; then
    echo "DSpark server healthy"
    ssh_head "curl -sS http://127.0.0.1:8000/v1/models || true"
    exit 0
  fi
  sleep 10
done

echo "Timed out waiting for DSpark health; recent logs:" >&2
ssh_head "docker logs --tail 120 vllm-dspark-head 2>&1 || true" >&2
ssh_worker "docker logs --tail 120 vllm-dspark-worker 2>&1 || true" >&2
exit 1

