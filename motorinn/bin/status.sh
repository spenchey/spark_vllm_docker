#!/usr/bin/env bash
# status.sh - Read-only summary of cluster status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "Cluster Status Summary (Read-Only)"
echo "=================================="
echo "HEAD_HOST: ${HEAD_HOST} (${HEAD_IP})"
echo "WORKER_HOST: ${WORKER_HOST} (${WORKER_IP})"
echo "RELEASE_PATH: ${RELEASE_PATH}"
echo "EXPECTED_RUNTIME_SHA: ${EXPECTED_RUNTIME_SHA}"
echo "EXPECTED_IMAGE_ID: ${EXPECTED_IMAGE_ID}"
echo "SERVED_MODEL: ${SERVED_MODEL}"
echo "MODEL_PATH: ${MODEL_PATH}"
echo "RDMA_INTERFACE: ${RDMA_INTERFACE}"
echo "MIN_MEMORY_GIB: ${MIN_MEMORY_GIB}"
echo "SHARD_COUNT: ${SHARD_COUNT}"
echo "ALLOW_MEDIA_STOP: ${ALLOW_MEDIA_STOP:-0}"
echo "=================================="
