#!/usr/bin/env bash
# verify-dspark-model-cache.sh - Validates one local host from arguments/environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Use provided model path or default
LOCAL_MODEL_PATH="${1:-${MODEL_PATH}}"

echo "Verifying local model cache at ${LOCAL_MODEL_PATH}"

# Check if directory exists
if [[ ! -d "${LOCAL_MODEL_PATH}" ]]; then
  echo "FAIL: Model path does not exist"
  exit 1
fi

# Check shard count (top-level)
shard_count=$(find "${LOCAL_MODEL_PATH}" -maxdepth 1 -name '*.safetensors' | wc -l)
if [[ ${shard_count} -ne ${SHARD_COUNT} ]]; then
  echo "FAIL: Shard count mismatch. Expected ${SHARD_COUNT}, got ${shard_count}"
  exit 1
fi

# Check index file SHA
if [[ ! -f "${LOCAL_MODEL_PATH}/model.safetensors.index.json" ]]; then
  echo "FAIL: model.safetensors.index.json not found"
  exit 1
fi

index_sha256=$(sha256sum "${LOCAL_MODEL_PATH}/model.safetensors.index.json" | awk '{print $1}')
echo "PASS: Local model cache verified. shard_count=${shard_count} index_sha256=${index_sha256}"
exit 0
