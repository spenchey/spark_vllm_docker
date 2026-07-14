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
# Using indexed arrays to be compatible with Bash 3.2 (no associative arrays)
HOSTS=("${HEAD_HOST}" "${WORKER_HOST}")
NUM_HOSTS=${#HOSTS[@]}

# Arrays to hold status fields for each host index
IDX_RUNTIME_SHA=()
IDX_DIRTY=()
IDX_IMAGE_ID=()
IDX_INDEX_SHA256=()
IDX_SHARD_COUNT=()
IDX_SERVED_MODEL=()
IDX_MEDIA_STATE=()
IDX_AVAILABLE_MEMORY_GIB=()
IDX_RDMA_UP=()
IDX_PEER_REACHABLE=()
IDX_PORTS_FREE=()

START_ALLOWED=true
MEDIA_BLOCKED=false

for (( i=0; i<NUM_HOSTS; i++ )); do
  host="${HOSTS[$i]}"

  # Default values for this host's check
  local_runtime_sha=""
  local_dirty="false"
  local_image_id=""
  local_index_sha256=""
  local_shard_count="0"
  local_served_model="${SERVED_MODEL}"
  local_media_state="none"
  local_available_memory_gib=0
  local_rdma_up="false"
  local_peer_reachable="false"
  local_ports_free="true"
  
  # 1. Check SSH connectivity and get runtime SHA
  # Capture git HEAD and status separately
  local_git_head=$(run_remote "$host" "cd ${RELEASE_PATH} && git rev-parse HEAD 2>/dev/null || echo 'ERROR'" 2>/dev/null) || { local_dirty="true"; local_git_head="unreachable"; }
  local_git_status=$(run_remote "$host" "cd ${RELEASE_PATH} && git status --porcelain 2>/dev/null || echo 'ERROR'" 2>/dev/null) || { local_dirty="true"; local_git_status="unreachable"; }

  if [[ "$local_git_head" == "ERROR" ]] || [[ "$local_git_head" == "unreachable" ]]; then
    local_dirty="true"
    local_runtime_sha="unreachable"
  elif [[ "$local_git_head" != "${EXPECTED_RUNTIME_SHA}" ]]; then
    local_dirty="true"
    local_runtime_sha="$local_git_head"
  else
    local_runtime_sha="$local_git_head"
  fi

  # Dirty means any status output
  if [[ -n "$local_git_status" ]] && [[ "$local_git_status" != "unreachable" ]]; then
    local_dirty="true"
  fi

  # 2. Check Image ID (Local image tag, not running container)
  # We inspect the local image tag vllm-dspark-runtime:dspark-nvfp4-stage-c
  if ! local_image_id=$(run_remote "$host" "docker image inspect --format='{{.Id}}' vllm-dspark-runtime:dspark-nvfp4-stage-c 2>/dev/null || echo 'ERROR'" 2>/dev/null); then
    local_image_id="unreachable"
    local_dirty="true"
  else
    if [[ "$local_image_id" == "ERROR" ]]; then
      local_dirty="true"
    elif [[ "$local_image_id" != "${EXPECTED_IMAGE_ID}" ]]; then
      local_dirty="true"
    fi
  fi

  # 3. Check Model Shards and Index SHA
  if ! local_shard_count=$(run_remote "$host" "find ${MODEL_PATH} -maxdepth 1 -name '*.safetensors' | wc -l" 2>/dev/null); then
    local_shard_count="0"
    local_dirty="true"
  fi
  
  if [[ "$local_shard_count" != "${SHARD_COUNT}" ]]; then
    local_dirty="true"
  fi

  if ! local_index_sha256=$(run_remote "$host" "sha256sum ${MODEL_PATH}/model.safetensors.index.json 2>/dev/null | awk '{print \$1}' || echo 'ERROR'" 2>/dev/null); then
    local_index_sha256="unreachable"
    local_dirty="true"
  else
    if [[ "$local_index_sha256" == "ERROR" ]]; then
      local_dirty="true"
    fi
  fi

  # 4. Check RDMA Interface
  if run_remote "$host" "ip link show ${RDMA_INTERFACE} | grep -q 'state UP' 2>/dev/null"; then
    local_rdma_up="true"
  else
    local_dirty="true"
  fi

  # 5. Check Peer Reachability (ICMP)
  if [[ "$host" == "${HEAD_HOST}" ]]; then
    peer_ip="${WORKER_IP}"
  else
    peer_ip="${HEAD_IP}"
  fi
  
  if run_remote "$host" "ping -c 1 -W 5 ${peer_ip} >/dev/null 2>&1"; then
    local_peer_reachable="true"
  else
    local_dirty="true"
  fi

  # 6. Check Ports (8000, 29500, 6379, 8265)
  for port in 8000 29500 6379 8265; do
    if check_port "$host" "$port"; then
      local_ports_free="false"
      local_dirty="true"
    else
      port_check_rc=$?
      if [[ $port_check_rc -ne 1 ]]; then
        local_ports_free="false"
        local_dirty="true"
      fi
    fi
  done

  # 7. Check Memory (Numeric available memory >=110)
  if ! local_available_memory_gib=$(run_remote "$host" "free -g | awk '/Mem:/ {print \$7}'" 2>/dev/null); then
    local_available_memory_gib=0
    local_dirty="true"
  fi
  
  # Validate available_memory_gib with a digits-only check before numeric comparison
  if [[ ! "$local_available_memory_gib" =~ ^[0-9]+$ ]]; then
    local_dirty="true"
    local_available_memory_gib=0
  else
    # Ensure numeric comparison
    if [[ ${local_available_memory_gib} -lt ${MIN_MEMORY_GIB} ]]; then
      local_dirty="true"
    fi
  fi

  # 8. Check Media
  if check_media "$host"; then
    local_media_state="blocked"
    MEDIA_BLOCKED=true
  else
    media_check_rc=$?
    if [[ $media_check_rc -eq 1 ]]; then
      local_media_state="none"
    else
      local_media_state="unknown"
      local_dirty="true"
    fi
  fi

  # Store status for this host index
  IDX_RUNTIME_SHA[$i]="$local_runtime_sha"
  IDX_DIRTY[$i]="$local_dirty"
  IDX_IMAGE_ID[$i]="$local_image_id"
  IDX_INDEX_SHA256[$i]="$local_index_sha256"
  IDX_SHARD_COUNT[$i]="$local_shard_count"
  IDX_SERVED_MODEL[$i]="$local_served_model"
  IDX_MEDIA_STATE[$i]="$local_media_state"
  IDX_AVAILABLE_MEMORY_GIB[$i]="$local_available_memory_gib"
  IDX_RDMA_UP[$i]="$local_rdma_up"
  IDX_PEER_REACHABLE[$i]="$local_peer_reachable"
  IDX_PORTS_FREE[$i]="$local_ports_free"

  # If any dirty flag is true, start_allowed becomes false
  if [[ "$local_dirty" == "true" ]]; then
    START_ALLOWED=false
  fi
done

# Cross-host index SHA comparison defect fix
# Map hosts to their indices for consistent access
HEAD_IDX=0
WORKER_IDX=1
if [[ "${HOSTS[0]}" == "${WORKER_HOST}" ]]; then
  HEAD_IDX=1
  WORKER_IDX=0
fi

HEAD_INDEX="${IDX_INDEX_SHA256[$HEAD_IDX]}"
WORKER_INDEX="${IDX_INDEX_SHA256[$WORKER_IDX]}"
if [[ -z "$HEAD_INDEX" ]] || [[ "$HEAD_INDEX" == "ERROR" ]] || [[ "$HEAD_INDEX" == "unreachable" ]]; then
  START_ALLOWED=false
fi
if [[ -z "$WORKER_INDEX" ]] || [[ "$WORKER_INDEX" == "ERROR" ]] || [[ "$WORKER_INDEX" == "unreachable" ]]; then
  START_ALLOWED=false
fi
if [[ "$HEAD_INDEX" != "$WORKER_INDEX" ]]; then
  START_ALLOWED=false
fi

# Final decision on start_allowed
if [[ "$MEDIA_BLOCKED" == "true" ]] && [[ "${ALLOW_MEDIA_STOP:-0}" != "1" ]]; then
  START_ALLOWED=false
fi

# Print machine-readable status for each host
for (( i=0; i<NUM_HOSTS; i++ )); do
  host="${HOSTS[$i]}"
  echo "host=${host}"
  echo "runtime_sha=${IDX_RUNTIME_SHA[$i]}"
  echo "dirty=${IDX_DIRTY[$i]}"
  echo "image_id=${IDX_IMAGE_ID[$i]}"
  echo "index_sha256=${IDX_INDEX_SHA256[$i]}"
  echo "shard_count=${IDX_SHARD_COUNT[$i]}"
  echo "served_model=${IDX_SERVED_MODEL[$i]}"
  echo "media_state=${IDX_MEDIA_STATE[$i]}"
  echo "available_memory_gib=${IDX_AVAILABLE_MEMORY_GIB[$i]}"
  echo "rdma_up=${IDX_RDMA_UP[$i]}"
  echo "peer_reachable=${IDX_PEER_REACHABLE[$i]}"
  echo "ports_free=${IDX_PORTS_FREE[$i]}"
  echo "---"
done

# If media exists, print blocked_media_in_use
if [[ "$MEDIA_BLOCKED" == "true" ]]; then
  echo "blocked_media_in_use=true"
fi

echo "start_allowed=${START_ALLOWED}"

# Exit code defect fix: exit 0 only if allowed, else 1
if [[ "$START_ALLOWED" == "true" ]]; then
  exit 0
else
  exit 1
fi
