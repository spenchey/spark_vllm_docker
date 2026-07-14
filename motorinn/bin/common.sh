#!/usr/bin/env bash
# common.sh - Shared constants and utility functions for MOT-2457 preflight
set -euo pipefail

# Defaults (environment-overridable)
export HEAD_HOST="${HEAD_HOST:-spark-2e61}"
export WORKER_HOST="${WORKER_HOST:-spark-cb87}"
export RELEASE_PATH="${RELEASE_PATH:-/home/spenchey/apps/spark_vllm_docker}"
export EXPECTED_RUNTIME_SHA="${EXPECTED_RUNTIME_SHA:-899e7ce7bbea4b2745e5981e45c11e02df80892f}"
export EXPECTED_IMAGE_ID="${EXPECTED_IMAGE_ID:-sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da}"
export SERVED_MODEL="${SERVED_MODEL:-deepseek-v4-flash-dspark}"
export MODEL_PATH="${MODEL_PATH:-/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark}"
export RDMA_INTERFACE="${RDMA_INTERFACE:-enp1s0f1np1}"
export HEAD_IP="${HEAD_IP:-169.254.135.115}"
export WORKER_IP="${WORKER_IP:-169.254.114.39}"
export MIN_MEMORY_GIB="${MIN_MEMORY_GIB:-110}"
export SHARD_COUNT="${SHARD_COUNT:-48}"

# SSH Options for BatchMode and timeouts
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

# Helper: Run command on remote host via SSH with bounded timeout
# Args: $1=host, $2=command
run_remote() {
  local host="$1"
  shift
  # Use timeout to bound the remote command execution
  timeout 30 ssh "${SSH_OPTS[@]}" "$host" "$@"
}

# Helper: Check if a port is in use on a remote host
# Args: $1=host, $2=port
check_port() {
  local host="$1"
  local port="$2"
  # Use ss to check for listening ports. Return 0 if in use, 1 if free.
  if run_remote "$host" "ss -tlnp | grep -q ':${port} ' 2>/dev/null"; then
    return 0 # Port is in use
  else
    return 1 # Port is free
  fi
}

# Helper: Check for media processes on remote host
# Args: $1=host
# Returns 0 if media is present, 1 if absent.
check_media() {
  local host="$1"
  
  # Check container names
  if run_remote "$host" "docker ps --format '{{.Names}}' | grep -qE 'comfyui-spark|comfyui-ollama' 2>/dev/null"; then
    return 0
  fi
  
  # Check running Python commands for ComfyUI
  if run_remote "$host" "ps aux | grep '[c]omfyui' 2>/dev/null"; then
    return 0
  fi
  
  return 1
}
