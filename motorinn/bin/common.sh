#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEAD_HOST="${HEAD_HOST:-spenchey@100.79.228.116}"
WORKER_HOST="${WORKER_HOST:-spenchey@100.126.94.26}"
HEAD_NAME="${HEAD_NAME:-spark-2e61}"
WORKER_NAME="${WORKER_NAME:-spark-cb87}"
HEAD_IP="${HEAD_IP:-169.254.135.115}"
WORKER_IP="${WORKER_IP:-169.254.114.39}"
ROCE_IF="${ROCE_IF:-enp1s0f1np1}"
IB_HCA="${IB_HCA:-rocep1s0f1}"
REMOTE_REPO="${REMOTE_REPO:-/home/spenchey/apps/spark_vllm_docker.factory-release}"

ssh_head() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${HEAD_HOST}" "$@"
}

ssh_worker() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${WORKER_HOST}" "$@"
}

load_env_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${file}"
}

