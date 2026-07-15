#!/usr/bin/env bash
# Regression test for MOT-2456: DSpark Compose, entrypoint, and model environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/motorinn/env/deepseek-v4-flash-dspark-tp2.env"
COMPOSE_FILE="docker-compose.yml"
ENTRYPOINT_FILE="entrypoints/entrypoint.unholy.sh"
TEST_SCRIPT="${BASH_SOURCE[0]}"

# Allowed paths for this card
ALLOWED_PATHS=(
  "docker-compose.yml"
  "entrypoints/entrypoint.unholy.sh"
  "motorinn/bin/common.sh"
  "motorinn/bin/preflight.sh"
  "motorinn/bin/start-dspark-tp2.sh"
  "motorinn/bin/status.sh"
  "motorinn/bin/stop-vllm-spark.sh"
  "motorinn/bin/verify-dspark-model-cache.sh"
  "motorinn/env/deepseek-v4-flash-dspark-tp2.env"
  "tests/test_motorinn_preflight.sh"
  "tests/test_motorinn_runtime.sh"
  "tests/test_motorinn_runtime_config.sh"
  "tests/test_motorinn_runtime_control.sh"
)

# Forbidden patterns for secrets/tokens
FORBIDDEN_PATTERNS=(
  "TOKEN"
  "SECRET"
  "PASSWORD"
  "API_KEY"
  "AUTHORIZATION"
  "PRIVATE_KEY"
)

FAILED=0

log_pass() {
  echo "[PASS] $1"
}

log_fail() {
  echo "[FAIL] $1"
  FAILED=1
}

echo "=== MOT-2456 Regression Test ==="

# 1. Syntax check on bash files
echo "--- Checking bash syntax ---"
bash -n "${ROOT_DIR}/${ENTRYPOINT_FILE}" || log_fail "entrypoint.unholy.sh has syntax errors"
bash -n "${TEST_SCRIPT}" || log_fail "test script has syntax errors"

# 2. Check that only allowed paths are modified
echo "--- Checking allowed paths ---"
CHANGED_PATHS=()
if git rev-parse --git-dir > /dev/null 2>&1; then
  # Get changed files from base commit
  while IFS= read -r line; do
    CHANGED_PATHS+=("$line")
  done < <(git diff --name-only bc334dd3e3770b3f7e9015d215f2ab3f65af4497)

  # Get untracked files
  while IFS= read -r line; do
    CHANGED_PATHS+=("$line")
  done < <(git ls-files --others --exclude-standard)
else
  # Fallback: if not in git, assume no changes (or handle as needed, but spec implies git context)
  : # No paths changed if not in repo
fi

# Sort and unique the changed paths
UNIQUE_CHANGED_PATHS=()
if [ ${#CHANGED_PATHS[@]} -gt 0 ]; then
  while IFS= read -r line; do
    UNIQUE_CHANGED_PATHS+=("$line")
  done < <(printf '%s\n' "${CHANGED_PATHS[@]}" | sort -u)
fi

# Check for any path outside allowed paths
if [ ${#UNIQUE_CHANGED_PATHS[@]} -gt 0 ]; then
  for path in "${UNIQUE_CHANGED_PATHS[@]}"; do
    allowed=0
    for allowed_path in "${ALLOWED_PATHS[@]}"; do
      if [ "$path" = "$allowed_path" ]; then
        allowed=1
        break
      fi
    done
    if [ $allowed -eq 0 ]; then
      log_fail "Unexpected path changed: ${path}"
    fi
  done
fi

# 2b. Check forbidden key names in environment file
echo "--- Checking forbidden secrets ---"
if grep -iE '^[A-Z_][A-Z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY|AUTHORIZATION|PRIVATE_KEY)=' "${ENV_FILE}" > /dev/null 2>&1; then
  log_fail "Environment file contains forbidden secret-like keys"
else
  log_pass "No forbidden secret patterns in environment file"
fi

# 3. Verify exact identity values in environment file
echo "--- Verifying environment values ---"
check_env_val() {
  local key="$1"
  local expected="$2"
  local actual
  actual=$(grep -E "^${key}=" "${ENV_FILE}" | head -n 1 | cut -d'=' -f2-)
  if [ "${actual}" = "${expected}" ]; then
    log_pass "${key}=${actual}"
  else
    log_fail "${key}: expected '${expected}', got '${actual}'"
  fi
}

check_env_val "VLLM_IMAGE" "vllm-dspark-runtime:dspark-nvfp4-stage-c"
check_env_val "EXPECTED_IMAGE_ID" "sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da"
check_env_val "MODEL_PATH" "/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark"
check_env_val "SERVED_MODEL_NAME" "deepseek-v4-flash-dspark"
check_env_val "HOST_PORT" "8000"
check_env_val "MAX_MODEL_LEN" "262144"
check_env_val "TP_SIZE" "2"

# 4. Verify RDMA values
echo "--- Verifying RDMA values ---"
check_env_val "HEAD_ROCE_IP" "169.254.135.115"
check_env_val "WORKER_ROCE_IP" "169.254.114.39"
check_env_val "ROCE_IF_NAME" "enp1s0f1np1"
check_env_val "IB_HCA_NAME" "rocep1s0f1"

# 5. Check compose passes through required variables
echo "--- Checking compose variable passthrough ---"
REQUIRED_VARS=(
  "VLLM_IMAGE"
  "MODEL_PATH"
  "SERVED_MODEL_NAME"
  "HOST_PORT"
  "MAX_MODEL_LEN"
  "TP_SIZE"
  "HEAD_ROCE_IP"
  "WORKER_ROCE_IP"
  "ROCE_IF_NAME"
  "IB_HCA_NAME"
)

for var in "${REQUIRED_VARS[@]}"; do
  if grep -q "\${${var}" "${ROOT_DIR}/${COMPOSE_FILE}" || grep -q "\${${var}:-" "${ROOT_DIR}/${COMPOSE_FILE}"; then
    log_pass "Compose references ${var}"
  else
    log_fail "Compose missing reference to ${var}"
  fi
done

# 6. Check entrypoint preserves structure
echo "--- Checking entrypoint structure ---"
if grep -q 'ROLE=head' "${ROOT_DIR}/${ENTRYPOINT_FILE}" && grep -q 'ROLE=worker' "${ROOT_DIR}/${ENTRYPOINT_FILE}"; then
  log_pass "Entrypoint preserves head/worker structure"
else
  log_fail "Entrypoint missing head/worker structure"
fi

if grep -q 'DISTRIBUTED_BACKEND.*mp' "${ROOT_DIR}/${ENTRYPOINT_FILE}"; then
  log_pass "Entrypoint enforces mp backend"
else
  log_fail "Entrypoint does not enforce mp backend"
fi

# 7. Check that environment file variables are consumed by entrypoint
echo "--- Checking variable consumption ---"
# Only check references on added lines in the diff for compose and entrypoint
ADDED_COMPOSE_VARS=()
ADDED_ENTRYPOINT_VARS=()

if git rev-parse --git-dir > /dev/null 2>&1; then
  # Get added lines in docker-compose.yml
  while IFS= read -r line; do
    if [[ "$line" =~ ^\+ ]]; then
      # Extract variable references like ${VAR} or ${VAR:-...}
      refs=$(echo "$line" | grep -oE '\$\{[A-Z_][A-Z0-9_]+(:-[^}]*)?\}' || true)
      for ref in $refs; do
        var_name=$(echo "$ref" | sed 's/\${//; s/:.*//')
        ADDED_COMPOSE_VARS+=("$var_name")
      done
    fi
  done < <(git diff bc334dd3e3770b3f7e9015d215f2ab3f65af4497 -- "${COMPOSE_FILE}")

  # Get added lines in entrypoint.unholy.sh
  while IFS= read -r line; do
    if [[ "$line" =~ ^\+ ]]; then
      refs=$(echo "$line" | grep -oE '\$\{[A-Z_][A-Z0-9_]+(:-[^}]*)?\}' || true)
      for ref in $refs; do
        var_name=$(echo "$ref" | sed 's/\${//; s/:.*//')
        ADDED_ENTRYPOINT_VARS+=("$var_name")
      done
    fi
  done < <(git diff bc334dd3e3770b3f7e9015d215f2ab3f65af4497 -- "${ENTRYPOINT_FILE}")
fi

# Combine all added vars to check against env file using newline-delimited scalar approach
ALL_ADDED_VARS_STR=""
if [ ${#ADDED_COMPOSE_VARS[@]} -gt 0 ]; then
  ALL_ADDED_VARS_STR=$(printf '%s\n' "${ADDED_COMPOSE_VARS[@]}")
fi
if [ ${#ADDED_ENTRYPOINT_VARS[@]} -gt 0 ]; then
  if [ -n "$ALL_ADDED_VARS_STR" ]; then
    ALL_ADDED_VARS_STR="${ALL_ADDED_VARS_STR}"
  fi
  ALL_ADDED_VARS_STR=$(printf '%s\n%s' "$ALL_ADDED_VARS_STR" "$(printf '%s\n' "${ADDED_ENTRYPOINT_VARS[@]}")")
fi

# Check that each added var has a matching KEY= line in the env file
if [ -n "$ALL_ADDED_VARS_STR" ]; then
  while IFS= read -r var; do
    if grep -qE "^${var}=" "${ENV_FILE}"; then
      log_pass "Env file contains key for added ref: ${var}"
    else
      log_fail "Env file missing key for added ref: ${var}"
    fi
  done <<< "$ALL_ADDED_VARS_STR"
else
  log_pass "No new variable references added in diff"
fi

# 8. Verify mandatory DSpark Compose environment values
echo "--- Verifying mandatory DSpark Compose environment values ---"
check_env_val "ENTRYPOINT_FILE" "./entrypoints/entrypoint.unholy.sh"
check_env_val "MODEL_CONTAINER_PATH" "/models/DeepSeek-V4-Flash-DSpark"
check_env_val "CLUSTER_MODE" "dual-rdma"
check_env_val "DISTRIBUTED_BACKEND" "mp"
check_env_val "MASTER_PORT" "29500"
check_env_val "MAX_NUM_SEQS" "1"
check_env_val "GPU_MEMORY_UTILIZATION" "0.80"
check_env_val "MAX_NUM_BATCHED_TOKENS" "8192"
check_env_val "TORCH_CUDA_ARCH_LIST" "12.1a"
check_env_val "FLASHINFER_CUDA_ARCH_LIST" "12.1a"
check_env_val "NCCL_NET" "IB"
check_env_val "NCCL_CROSS_NIC" "1"
check_env_val "NCCL_CUMEM_ENABLE" "0"
check_env_val "NCCL_IGNORE_CPU_AFFINITY" "1"
check_env_val "NCCL_NVLS_ENABLE" "0"

echo "=============================="
if [ ${FAILED} -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
