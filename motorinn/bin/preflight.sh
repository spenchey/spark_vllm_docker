#!/usr/bin/env bash
# preflight.sh - Read-only clean-cluster preflight for the two Sparks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [[ $# -ne 1 ]] || [[ "$1" != "--check-only" ]]; then
  echo "Usage: $0 --check-only" >&2
  exit 1
fi

# Initialize status variables for each host
declare -A HOST_STATUS
HOSTS=("${HEAD_HOST}" "${WORKER_HOST}")
START_ALLOWED=true
MEDIA_BLOCKED=false

for host in "${HOSTS[@]}"; do
  # Default values for this host's check
  runtime_sha=""
  dirty="false"
  image_id=""
  index_sha256=""
  shard_count="0"
  served_model=""
  media_state="none"
  available_memory_gib=0
  rdma_up="false"
  peer_reachable="false"
  ports_free="true"
  
  # 1. Check SSH connectivity and get runtime SHA
  if ! runtime_sha=$(run_remote "$host" "cd ${RELEASE_PATH} && git rev-parse HEAD 2>/dev/null || echo 'ERROR'" 2>/dev/null); then
    # SSH failed or command failed
    dirty="true"
    runtime_sha="unreachable"
  else
    if [[ "$runtime_sha" == "ERROR" ]]; then
      dirty="true"
      runtime_sha="invalid"
    elif [[ "$runtime_sha" != "${EXPECTED_RUNTIME_SHA}" ]]; then
      dirty="true"
    fi
  fi

  # 2. Check Image ID
  if ! image_id=$(run_remote "$host" "docker inspect --format='{{.Id}}' $(docker ps -q --filter 'ancestor=spark_vllm_docker' | head -1) 2>/dev/null || echo 'ERROR'" 2>/dev/null); then
    # Try to get image ID from running container if possible, or just check if docker works
    # If we can't get it, assume mismatch for safety in fail-closed
    image_id="unreachable"
    dirty="true"
  else
    if [[ "$image_id" != "${EXPECTED_IMAGE_ID}" ]]; then
      dirty="true"
    fi
  fi

  # 3. Check Model Shards and Index SHA
  if ! shard_count=$(run_remote "$host" "find ${MODEL_PATH} -name '*.safetensors' | wc -l" 2>/dev/null); then
    shard_count="0"
    dirty="true"
  fi
  
  if [[ "$shard_count" != "${SHARD_COUNT}" ]]; then
    dirty="true"
  fi

  if ! index_sha256=$(run_remote "$host" "sha256sum ${MODEL_PATH}/model.safetensors.index.json 2>/dev/null | awk '{print \$1}' || echo 'ERROR'" 2>/dev/null); then
    index_sha256="unreachable"
    dirty="true"
  else
    if [[ "$index_sha256" == "ERROR" ]]; then
      dirty="true"
    fi
  fi

  # 4. Check RDMA Interface
  if run_remote "$host" "ip link show ${RDMA_INTERFACE} | grep -q 'state UP' 2>/dev/null"; then
    rdma_up="true"
  else
    dirty="true"
  fi

  # 5. Check Peer Reachability (ICMP)
  if [[ "$host" == "${HEAD_HOST}" ]]; then
    peer_ip="${WORKER_IP}"
  else
    peer_ip="${HEAD_IP}"
  fi
  
  if run_remote "$host" "ping -c 1 -W 5 ${peer_ip} >/dev/null 2>&1"; then
    peer_reachable="true"
  else
    dirty="true"
  fi

  # 6. Check Ports (8000, 29500, 6379, 8265)
  for port in 8000 29500 6379 8265; do
    if check_port "$host" "$port"; then
      ports_free="false"
      dirty="true"
    fi
  done

  # 7. Check Memory
  if ! available_memory_gib=$(run_remote "$host" "free -g | awk '/Mem:/ {print \$7}'" 2>/dev/null); then
    available_memory_gib=0
    dirty="true"
  fi
  
  if [[ ${available_memory_gib} -lt ${MIN_MEMORY_GIB} ]]; then
    dirty="true"
  fi

  # 8. Check Media
  if check_media "$host"; then
    media_state="blocked"
    MEDIA_BLOCKED=true
  else
    media_state="none"
  fi

  # Store status for this host
  HOST_STATUS["${host}_runtime_sha"]="$runtime_sha"
  HOST_STATUS["${host}_dirty"]="$dirty"
  HOST_STATUS["${host}_image_id"]="$image_id"
  HOST_STATUS["${host}_index_sha256"]="$index_sha256"
  HOST_STATUS["${host}_shard_count"]="$shard_count"
  HOST_STATUS["${host}_served_model"]="${SERVED_MODEL}"
  HOST_STATUS["${host}_media_state"]="$media_state"
  HOST_STATUS["${host}_available_memory_gib"]="$available_memory_gib"
  HOST_STATUS["${host}_rdma_up"]="$rdma_up"
  HOST_STATUS["${host}_peer_reachable"]="$peer_reachable"
  HOST_STATUS["${host}_ports_free"]="$ports_free"

  # If any dirty flag is true, start_allowed becomes false
  if [[ "$dirty" == "true" ]]; then
    START_ALLOWED=false
  fi
done

# Final decision on start_allowed
if [[ "$MEDIA_BLOCKED" == "true" ]] && [[ "${ALLOW_MEDIA_STOP:-0}" != "1" ]]; then
  START_ALLOWED=false
fi

# Print machine-readable status for each host
for host in "${HOSTS[@]}"; do
  echo "host=${host}"
  echo "runtime_sha=${HOST_STATUS[${host}_runtime_sha]}"
  echo "dirty=${HOST_STATUS[${host}_dirty]}"
  echo "image_id=${HOST_STATUS[${host}_image_id]}"
  echo "index_sha256=${HOST_STATUS[${host}_index_sha256]}"
  echo "shard_count=${HOST_STATUS[${host}_shard_count]}"
  echo "served_model=${HOST_STATUS[${host}_served_model]}"
  echo "media_state=${HOST_STATUS[${host}_media_state]}"
  echo "available_memory_gib=${HOST_STATUS[${host}_available_memory_gib]}"
  echo "rdma_up=${HOST_STATUS[${host}_rdma_up]}"
  echo "peer_reachable=${HOST_STATUS[${host}_peer_reachable]}"
  echo "ports_free=${HOST_STATUS[${host}_ports_free]}"
  echo "---"
done

echo "start_allowed=${START_ALLOWED}"
