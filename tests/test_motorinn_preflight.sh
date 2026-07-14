#!/usr/bin/env bash
# test_motorinn_preflight.sh - Regression tests for MOT-2457 preflight
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/../motorinn/bin"
ORIGINAL_PATH="$PATH"

echo "Running MOT-2457 Preflight Tests..."

# Constants for expected values
EXPECTED_SHA="899e7ce7bbea4b2745e5981e45c11e02df80892f"
EXPECTED_IMAGE_ID="sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da"
EXPECTED_INDEX_SHA="abc123def456"

# Global Fixture Root
FIXTURE_ROOT=$(mktemp -d)
trap "rm -rf \"${FIXTURE_ROOT}\"" EXIT

FAKE_BIN="${FIXTURE_ROOT}/fake_bin"
MOCK_STATE_DIR="${FIXTURE_ROOT}/state"
OUTPUT_FILE="${FIXTURE_ROOT}/output"
ERROR_FILE="${FIXTURE_ROOT}/error"
MOCK_COMMAND_LOG="${FIXTURE_ROOT}/log"

mkdir -p "${FAKE_BIN}" "${MOCK_STATE_DIR}"

# Create fake ssh script
cat > "${FAKE_BIN}/ssh" << 'SSHEOF'
#!/usr/bin/env bash
LOG_FILE="${MOCK_COMMAND_LOG}"
echo "$*" >> "${LOG_FILE}"

if [[ -f "${MOCK_STATE_DIR}/ssh_fail" ]]; then
  exit 1
fi

CMD="$*"
NORMALIZED_CMD="${CMD//\\/}"
IS_WORKER=0
if echo "$NORMALIZED_CMD" | grep -q "spark-cb87"; then
  IS_WORKER=1
fi

# Detect command type using case wildcards to handle escaped spaces
if echo "$NORMALIZED_CMD" | grep -q "printf reachable"; then
  echo "reachable"
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "git rev-parse HEAD"; then
  if [[ $IS_WORKER -eq 1 ]] && [[ -f "${MOCK_STATE_DIR}/worker_git_sha" ]]; then
    cat "${MOCK_STATE_DIR}/worker_git_sha"
  elif [[ -f "${MOCK_STATE_DIR}/git_sha" ]]; then
    cat "${MOCK_STATE_DIR}/git_sha"
  else
    echo "899e7ce7bbea4b2745e5981e45c11e02df80892f"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "git status --porcelain"; then
  if [[ -f "${MOCK_STATE_DIR}/git_dirty" ]]; then
    cat "${MOCK_STATE_DIR}/git_dirty"
  else
    echo ""
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "docker image inspect"; then
  if [[ -f "${MOCK_STATE_DIR}/image_id" ]]; then
    cat "${MOCK_STATE_DIR}/image_id"
  else
    echo "sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "find.*safetensors.*wc -l"; then
  if [[ -f "${MOCK_STATE_DIR}/shard_count" ]]; then
    cat "${MOCK_STATE_DIR}/shard_count"
  else
    echo "48"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "sha256sum.*index.json"; then
  if [[ $IS_WORKER -eq 1 ]] && [[ -f "${MOCK_STATE_DIR}/worker_index_sha" ]]; then
    cat "${MOCK_STATE_DIR}/worker_index_sha"
  elif [[ -f "${MOCK_STATE_DIR}/index_sha" ]]; then
    cat "${MOCK_STATE_DIR}/index_sha"
  else
    echo "abc123def456"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "ip link show.*enp1s0f1np1"; then
  if [[ -f "${MOCK_STATE_DIR}/rdma_down" ]]; then
    exit 1
  fi
  echo "state UP"
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "ping.*169.254"; then
  if [[ -f "${MOCK_STATE_DIR}/peer_fail" ]]; then
    exit 1
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "ss -H -ltn"; then
  port=""
  case "$NORMALIZED_CMD" in
    *:8000*) port="8000" ;;
    *:29500*) port="29500" ;;
    *:6379*) port="6379" ;;
    *:8265*) port="8265" ;;
  esac
  if [[ -n "$port" ]] && [[ -f "${MOCK_STATE_DIR}/port_${port}" ]]; then
    echo "occupied"
  else
    echo "free"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "free -g"; then
  if [[ -f "${MOCK_STATE_DIR}/memory_low" ]]; then
    echo "50"
  else
    echo "246"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "docker ps"; then
  if [[ -f "${MOCK_STATE_DIR}/media_container" ]]; then
    echo "present"
  else
    echo "absent"
  fi
  exit 0
fi

if echo "$NORMALIZED_CMD" | grep -q "ps aux"; then
  if [[ -f "${MOCK_STATE_DIR}/media_ps" ]]; then
    echo "present"
  else
    echo "absent"
  fi
  exit 0
fi

exit 99
SSHEOF
chmod +x "${FAKE_BIN}/ssh"

# Create fake ss
cat > "${FAKE_BIN}/ss" << 'SSEOF'
#!/usr/bin/env bash
exit 1
SSEOF
chmod +x "${FAKE_BIN}/ss"

# Create fake docker
cat > "${FAKE_BIN}/docker" << 'DOCKEOF'
#!/usr/bin/env bash
exit 1
DOCKEOF
chmod +x "${FAKE_BIN}/docker"

# Create fake ping
cat > "${FAKE_BIN}/ping" << 'PINGEOF'
#!/usr/bin/env bash
exit 1
PINGEOF
chmod +x "${FAKE_BIN}/ping"

# Create fake free
cat > "${FAKE_BIN}/free" << 'FREEEOF'
#!/usr/bin/env bash
echo "246"
FREEEOF
chmod +x "${FAKE_BIN}/free"

# Create fake ps
cat > "${FAKE_BIN}/ps" << 'PSEOF'
#!/usr/bin/env bash
exit 0
PSEOF
chmod +x "${FAKE_BIN}/ps"

# Create fake ip
cat > "${FAKE_BIN}/ip" << 'IPEOF'
#!/usr/bin/env bash
echo "state UP"
IPEOF
chmod +x "${FAKE_BIN}/ip"

# Create fake find
cat > "${FAKE_BIN}/find" << 'FINDEOF'
#!/usr/bin/env bash
exit 0
FINDEOF
chmod +x "${FAKE_BIN}/find"

# Create fake sha256sum
cat > "${FAKE_BIN}/sha256sum" << 'SHAEOF'
#!/usr/bin/env bash
echo "abc123def456  index.json"
SHAEOF
chmod +x "${FAKE_BIN}/sha256sum"

# Create fake git
cat > "${FAKE_BIN}/git" << 'GITEOF'
#!/usr/bin/env bash
exit 0
GITEOF
chmod +x "${FAKE_BIN}/git"

reset_state() {
  rm -f "${MOCK_STATE_DIR}"/*
  > "${MOCK_COMMAND_LOG}"
  > "${OUTPUT_FILE}"
  > "${ERROR_FILE}"
}

run_preflight_test() {
  local allow_media="$1"

  set +e
  ALLOW_MEDIA_STOP="$allow_media" EXPECTED_RUNTIME_SHA="$EXPECTED_SHA" PATH="${FAKE_BIN}:${ORIGINAL_PATH}" MOCK_STATE_DIR="${MOCK_STATE_DIR}" MOCK_COMMAND_LOG="${MOCK_COMMAND_LOG}" /bin/bash "${BIN_DIR}/preflight.sh" --check-only > "${OUTPUT_FILE}" 2> "${ERROR_FILE}"
  RUN_EXIT=$?
  set -e
}

assert_exit() {
  local expected="$1"
  local actual="$2"
  if [[ "$expected" -ne "$actual" ]]; then
    echo "FAIL: Expected exit code $expected, got $actual"
    return 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -q "$pattern" "$file"; then
    echo "FAIL: Pattern '$pattern' not found in $file"
    cat "$file"
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -q "$pattern" "$file"; then
    echo "FAIL: Pattern '$pattern' found in $file but should not be"
    cat "$file"
    return 1
  fi
}

assert_exact_line() {
  local file="$1"
  local expected="$2"
  if ! grep -qx "$expected" "$file"; then
    echo "FAIL: Exact line '$expected' not found in $file"
    cat "$file"
    return 1
  fi
}

# Test 1: Pass (All clean)
echo "Test 1: Pass (All clean)"
reset_state
run_preflight_test "0"
assert_exit 0 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=true" || exit 1
assert_contains "${MOCK_COMMAND_LOG}" "spenchey@spark-2e61" || exit 1
assert_contains "${MOCK_COMMAND_LOG}" "spenchey@spark-cb87" || exit 1
echo "PASS: Test 1"

# Test 2: Total SSH Failure
echo "Test 2: SSH Failure"
reset_state
touch "${MOCK_STATE_DIR}/ssh_fail"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
if [[ $(wc -l < "${MOCK_COMMAND_LOG}") -ne 2 ]]; then
  echo "FAIL: Unreachable hosts should be probed exactly once each"
  cat "${MOCK_COMMAND_LOG}"
  exit 1
fi
echo "PASS: Test 2"

# Test 3: Dirty Repo (SHA Mismatch)
echo "Test 3: Dirty Repo"
reset_state
echo " M file" > "${MOCK_STATE_DIR}/git_dirty"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 3"

# Test 4: Expected Runtime SHA Mismatch
echo "Test 4: SHA Mismatch"
reset_state
echo "bad_sha" > "${MOCK_STATE_DIR}/git_sha"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 4"

# Test 5: Different Host Runtime SHAs (Simulated by changing expected SHA in mock)
echo "Test 5: Host SHA Mismatch"
reset_state
echo "bad_sha" > "${MOCK_STATE_DIR}/worker_git_sha"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 5"

# Test 6: Shard Mismatch
echo "Test 6: Shard Mismatch"
reset_state
echo "47" > "${MOCK_STATE_DIR}/shard_count"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 6"

# Test 7: Unequal Host Index Hashes
echo "Test 7: Index SHA Mismatch"
reset_state
echo "bad_sha" > "${MOCK_STATE_DIR}/worker_index_sha"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 7"

# Test 8: Image Mismatch
echo "Test 8: Image ID Mismatch"
reset_state
echo "sha256:bad" > "${MOCK_STATE_DIR}/image_id"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 8"

# Test 9: RDMA Down
echo "Test 9: RDMA Down"
reset_state
touch "${MOCK_STATE_DIR}/rdma_down"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 9"

# Test 10: Peer Failure
echo "Test 10: Peer Failure"
reset_state
touch "${MOCK_STATE_DIR}/peer_fail"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 10"

# Test 11: Occupied Port 8000
echo "Test 11: Occupied Port 8000"
reset_state
touch "${MOCK_STATE_DIR}/port_8000"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 11"

# Test 12: Occupied Port 29500
echo "Test 12: Occupied Port 29500"
reset_state
touch "${MOCK_STATE_DIR}/port_29500"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 12"

# Test 13: Occupied Port 6379
echo "Test 13: Occupied Port 6379"
reset_state
touch "${MOCK_STATE_DIR}/port_6379"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 13"

# Test 14: Occupied Port 8265
echo "Test 14: Occupied Port 8265"
reset_state
touch "${MOCK_STATE_DIR}/port_8265"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 14"

# Test 15: Low Memory
echo "Test 15: Low Memory"
reset_state
touch "${MOCK_STATE_DIR}/memory_low"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=false" || exit 1
echo "PASS: Test 15"

# Test 16: Media Container Blocked
echo "Test 16: Media Container Blocked"
reset_state
touch "${MOCK_STATE_DIR}/media_container"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_exact_line "${OUTPUT_FILE}" "blocked_media_in_use=true" || exit 1
echo "PASS: Test 16"

# Test 17: Media Python Process Blocked
echo "Test 17: Media Python Process Blocked"
reset_state
touch "${MOCK_STATE_DIR}/media_ps"
run_preflight_test "0"
assert_exit 1 $RUN_EXIT || exit 1
assert_exact_line "${OUTPUT_FILE}" "blocked_media_in_use=true" || exit 1
echo "PASS: Test 17"

# Test 18: Media Override (ALLOW_MEDIA_STOP=1)
echo "Test 18: Media Override"
reset_state
touch "${MOCK_STATE_DIR}/media_container"
touch "${MOCK_STATE_DIR}/media_ps"
run_preflight_test "1"
assert_exit 0 $RUN_EXIT || exit 1
assert_contains "${OUTPUT_FILE}" "start_allowed=true" || exit 1
assert_exact_line "${OUTPUT_FILE}" "blocked_media_in_use=true" || exit 1
# Verify no mutating commands in log
assert_not_contains "${MOCK_COMMAND_LOG}" "docker stop" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "docker start" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "docker rm" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "docker compose" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "docker up" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "docker down" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "kill" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "pkill" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "systemctl start" || exit 1
assert_not_contains "${MOCK_COMMAND_LOG}" "systemctl stop" || exit 1
echo "PASS: Test 18"

# Test 19: Verify no mutating commands in production scripts
echo "Test 19: No Mutating Commands in Production Scripts"
violations=$(awk '
  /^[[:space:]]*#/ { next }
  /(^|[[:space:];|&()])docker[[:space:]]+(start|stop|rm|compose|up|down)([[:space:];|&()]|$)/ ||
  /(^|[[:space:];|&()])(kill|pkill|mv|cp|rsync|scp|tee|truncate|touch|mkdir|rm)([[:space:];|&()]|$)/ ||
  /(^|[[:space:];|&()])systemctl[[:space:]]+(start|stop)([[:space:];|&()]|$)/ ||
  /(^|[[:space:];|&()])sed[[:space:]]+-i([[:space:];|&()]|$)/ ||
  /(^|[[:space:];|&()])git[[:space:]]+(checkout|reset|clean|pull)([[:space:];|&()]|$)/ {
    print FILENAME ":" FNR ":" $0
  }
' "${BIN_DIR}/preflight.sh" "${BIN_DIR}/common.sh" "${BIN_DIR}/status.sh" "${BIN_DIR}/verify-dspark-model-cache.sh")
if [[ -n "$violations" ]]; then
  echo "FAIL: Test 19 - Found mutating production command"
  echo "$violations"
  exit 1
fi
echo "PASS: Test 19"

echo "All tests passed!"
exit 0
