#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

ENV_FILE="${1:-${REPO_ROOT}/motorinn/env/deepseek-v4-flash-dspark-tp2.env}"
if [ ! -f "${ENV_FILE}" ]; then
  echo "missing env file: ${ENV_FILE}" >&2
  exit 2
fi

MODEL_PATH="$(load_env_value "${ENV_FILE}" MODEL_PATH)"
IMAGE="$(load_env_value "${ENV_FILE}" VLLM_IMAGE)"
HOST_PORT="$(load_env_value "${ENV_FILE}" HOST_PORT)"
MASTER_PORT="$(load_env_value "${ENV_FILE}" MASTER_PORT || true)"
RAY_PORT="$(load_env_value "${ENV_FILE}" RAY_PORT || true)"

echo "preflight env=${ENV_FILE}"
echo "model=${MODEL_PATH}"
echo "image=${IMAGE}"

if [[ "${MODEL_PATH}" != /home/spenchey/models/* ]]; then
  echo "model path must be on each Spark's local NVMe under /home/spenchey/models" >&2
  exit 2
fi

for role in head worker; do
  if [ "${role}" = head ]; then
    host_fn=ssh_head
    peer_ip="${WORKER_IP}"
  else
    host_fn=ssh_worker
    peer_ip="${HEAD_IP}"
  fi
  echo
  echo "== ${role} checks =="
  ${host_fn} "set -e
    test -d '${MODEL_PATH}' || { echo 'missing model path ${MODEL_PATH}'; exit 10; }
    test -f '${MODEL_PATH}/config.json' || { echo 'missing config.json'; exit 11; }
    docker image inspect '${IMAGE}' >/dev/null 2>&1 || { echo 'missing image ${IMAGE}'; exit 12; }
    ip link show '${ROCE_IF}' >/dev/null
    rdma link show | grep -q '${IB_HCA}.*ACTIVE' || { echo 'rdma link ${IB_HCA} not ACTIVE'; exit 13; }
    ping -c 2 -W 2 -I '${ROCE_IF}' '${peer_ip}' >/dev/null
    python3 - <<'PY'
import pathlib, sys
avail = int(pathlib.Path('/proc/meminfo').read_text().split('MemAvailable:')[1].split()[0])
print(f'MemAvailable={avail//1024} MiB')
if avail < 110 * 1024 * 1024:
    print('not enough clean memory for full DeepSeek load; stop workloads and reboot/drop cache first', file=sys.stderr)
    sys.exit(14)
PY
    ss -ltn | grep -q ':${HOST_PORT} ' && { echo 'port ${HOST_PORT} already in use'; exit 15; } || true
    if [ -n '${MASTER_PORT}' ]; then ss -ltn | grep -q ':${MASTER_PORT} ' && { echo 'master port ${MASTER_PORT} already in use'; exit 16; } || true; fi
    if [ -n '${RAY_PORT}' ]; then ss -ltn | grep -q ':${RAY_PORT} ' && { echo 'ray port ${RAY_PORT} already in use'; exit 17; } || true; fi
  "
done

echo
echo "preflight passed"

