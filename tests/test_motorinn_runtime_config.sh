#!/usr/bin/env bash
# Regression test for MOT-2456: DSpark Compose, entrypoint, and model environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/motorinn/env/deepseek-v4-flash-dspark-tp2.env"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
ENTRYPOINT_FILE="${ROOT_DIR}/entrypoints/entrypoint.unholy.sh"
TEST_SCRIPT="${BASH_SOURCE[0]}"

# Allowed paths for this card
ALLOWED_PATHS=(
  "docker-compose.yml"
  "entrypoints/entrypoint.unholy.sh"
  "motorinn/env/deepseek-v4-flash-dspark-tp2.env"
  "tests/test_motorinn_runtime_config.sh"
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
bash -n "${ENTRYPOINT_FILE}" || log_fail "entrypoint.unholy.sh has syntax errors"
bash -n "${TEST_SCRIPT}" || log_fail "test script has syntax errors"

# 2. Check that only allowed paths are modified (simulated by checking existence)
echo "--- Checking allowed paths ---"
for path in "${ALLOWED_PATHS[@]}"; do
  if [ ! -f "${ROOT_DIR}/${path}" ]; then
    log_fail "Allowed file missing: ${path}"
  fi
done

# 2b. Check forbidden key names in environment file
echo "--- Checking forbidden secrets ---"
if grep -iE '(TOKEN|SECRET|PASSWORD|API_KEY|AUTHORIZATION|PRIVATE_KEY)' "${ENV_FILE}" > /dev/null 2>&1; then
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
  if grep -q "\${${var}" "${COMPOSE_FILE}" || grep -q "\${${var}:-" "${COMPOSE_FILE}"; then
    log_pass "Compose references ${var}"
  else
    log_fail "Compose missing reference to ${var}"
  fi
done

# 6. Check entrypoint preserves structure
echo "--- Checking entrypoint structure ---"
if grep -q 'ROLE=head' "${ENTRYPOINT_FILE}" && grep -q 'ROLE=worker' "${ENTRYPOINT_FILE}"; then
  log_pass "Entrypoint preserves head/worker structure"
else
  log_fail "Entrypoint missing head/worker structure"
fi

if grep -q 'DISTRIBUTED_BACKEND.*mp' "${ENTRYPOINT_FILE}"; then
  log_pass "Entrypoint enforces mp backend"
else
  log_fail "Entrypoint does not enforce mp backend"
fi

# 7. Check that environment file variables are consumed by entrypoint
echo "--- Checking variable consumption ---"
ENV_VARS=$(grep -E '^[A-Z_]+=' "${ENV_FILE}" | cut -d'=' -f1)
for var in ${ENV_VARS}; do
  # Skip image and hash as they are not directly consumed as env vars in the same way
  if [[ "${var}" == "VLLM_IMAGE" || "${var}" == "EXPECTED_IMAGE_ID" ]]; then
    continue
  fi
  # Check if the variable is referenced in the entrypoint (either as ${VAR} or ${VAR:-default})
  if grep -qE "\$\{${var}(:-[^}]*)?\}" "${ENTRYPOINT_FILE}"; then
    log_pass "Entrypoint consumes ${var}"
  else
    log_fail "Entrypoint missing reference to ${var}"
  fi
done

echo "=============================="
if [ ${FAILED} -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
