#!/usr/bin/env bash
# common.sh - Shared constants and utility functions for MOT-2457 preflight
set -euo pipefail

# Defaults (environment-overridable)
export HEAD_HOST="${HEAD_HOST:-spark-2e61}"
export WORKER_HOST="${WORKER_HOST:-spark-cb87}"
export SSH_USER="${SSH_USER:-spenchey}"
export REMOTE_REPO="${REMOTE_REPO:-${RELEASE_PATH:-/home/spenchey/apps/spark_vllm_docker.factory-release}}"
export RELEASE_PATH="${REMOTE_REPO}"
: "${EXPECTED_RUNTIME_SHA:?EXPECTED_RUNTIME_SHA must be supplied}"
export EXPECTED_RUNTIME_SHA
export EXPECTED_IMAGE_ID="${EXPECTED_IMAGE_ID:-sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da}"
export SERVED_MODEL="${SERVED_MODEL:-deepseek-v4-flash-dspark}"
export MODEL_PATH="${MODEL_PATH:-/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark}"
export RDMA_INTERFACE="${RDMA_INTERFACE:-enp1s0f1np1}"
export HEAD_IP="${HEAD_IP:-169.254.135.115}"
export WORKER_IP="${WORKER_IP:-169.254.114.39}"
export MIN_MEMORY_GIB="${MIN_MEMORY_GIB:-110}"
export SHARD_COUNT="${SHARD_COUNT:-48}"
export RUNTIME_PORT="${RUNTIME_PORT:-8888}"

# SSH Options for BatchMode and timeouts
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

# Helper: Run command on remote host via SSH with bounded timeout
# Args: $1=host, $2=command
run_remote() {
  local host="$1"
  shift
  local target="$host"
  if [[ "$target" != *@* ]]; then
    target="${SSH_USER}@${target}"
  fi
  # Join remaining arguments into a single command string
  local command="$*"
  # Safely quote the command string using Bash printf -v with %q before passing it to ssh.
  local quoted_cmd
  printf -v quoted_cmd '%q' "$command"
  ssh "${SSH_OPTS[@]}" "$target" "timeout 25s bash -lc ${quoted_cmd}"
}

# Helper: Check if a port is in use on a remote host
# Args: $1=host, $2=port
check_port() {
  local host="$1"
  local port="$2"
  local state rc
  # Return 0 when occupied, 1 when free, and 2 when the check itself failed.
  state=$(run_remote "$host" "command -v ss >/dev/null 2>&1 || { printf error; exit; }; listeners=\$(ss -H -ltn 'sport = :${port}' 2>/dev/null) || { printf error; exit; }; if [ -n \"\$listeners\" ]; then printf occupied; else printf free; fi")
  rc=$?
  [[ $rc -eq 0 ]] || return 2
  [[ "$state" == "occupied" ]] && return 0
  [[ "$state" == "free" ]] && return 1
  return 2
}

# Helper: Check for media processes on remote host
# Args: $1=host
# Returns 0 if media is present, 1 if absent.
check_media() {
  local host="$1"
  local state rc

  # Check container names
  state=$(run_remote "$host" "command -v docker >/dev/null 2>&1 || { printf error; exit; }; names=\$(docker ps --format '{{.Names}}' 2>/dev/null) || { printf error; exit; }; if printf '%s\\n' \"\$names\" | grep -qE 'comfyui-spark|comfyui-ollama'; then printf present; else printf absent; fi")
  rc=$?
  [[ $rc -eq 0 ]] || return 2
  [[ "$state" == "present" ]] && return 0
  [[ "$state" == "absent" ]] || return 2

  # Check running Python commands for ComfyUI
  state=$(run_remote "$host" "command -v ps >/dev/null 2>&1 || { printf error; exit; }; processes=\$(ps aux 2>/dev/null) || { printf error; exit; }; if printf '%s\\n' \"\$processes\" | grep '[c]omfyui' >/dev/null; then printf present; else printf absent; fi")
  rc=$?
  [[ $rc -eq 0 ]] || return 2
  [[ "$state" == "present" ]] && return 0
  [[ "$state" == "absent" ]] && return 1
  return 2
}
