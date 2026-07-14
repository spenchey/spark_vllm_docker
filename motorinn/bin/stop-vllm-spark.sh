#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "Stopping only vLLM/Ray containers created by Spark model serving. ComfyUI is left alone."
for target in head worker; do
  if [ "${target}" = head ]; then
    host_fn=ssh_head
  else
    host_fn=ssh_worker
  fi
  echo "== ${target} =="
  ${host_fn} "set -e
    cd '${REMOTE_REPO}' 2>/dev/null || true
    docker rm -f vllm-spark-head vllm-spark-worker vllm-dspark-head vllm-dspark-worker vllm-head vllm-worker 2>/dev/null || true
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    ray stop --force 2>/dev/null || true
  "
done

