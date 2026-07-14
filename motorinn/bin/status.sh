#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

echo "== repo =="
echo "${REPO_ROOT}"
git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD
git -C "${REPO_ROOT}" rev-parse --short HEAD

echo
echo "== model downloads on Sparks =="
"${REPO_ROOT}/motorinn/bin/model-download-status.sh"

echo
echo "== head ${HEAD_NAME} =="
ssh_head "hostname; ip -br addr show ${ROCE_IF}; rdma link show | grep ${IB_HCA} || true; docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'; curl -sS --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null || true; free -h | sed -n '1,2p'"

echo
echo "== worker ${WORKER_NAME} =="
ssh_worker "hostname; ip -br addr show ${ROCE_IF}; rdma link show | grep ${IB_HCA} || true; docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'; free -h | sed -n '1,2p'"

