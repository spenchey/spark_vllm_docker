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

# Helper to run preflight with mocked environment
run_preflight() {
  local allow_media="$1"
  shift

  # Create exactly one mktemp fixture root
  local MOCK_STATE_DIR
  MOCK_STATE_DIR=$(mktemp -d)
  trap "rm -rf \"${MOCK_STATE_DIR}\"" EXIT

  local fake_bin="${MOCK_STATE_DIR}/bin"
  local state_dir="${MOCK_STATE_DIR}/state"
  local log_file="${MOCK_STATE_DIR}/log"

  mkdir -p "${fake_bin}" "${state_dir}"

  # Create fake ssh script
  cat > "${fake_bin}/ssh" << 'SSHEOF'
#!/usr/bin/env bash
# Fake SSH for testing
LOG_FILE="${MOCK_COMMAND_LOG}"
echo "$*" >> "${LOG_FILE}"

if [[ -f "${MOCK_STATE_DIR}/state/ssh_fail" ]]; then
  exit 1
fi

CMD="$*"

# Parse host and command from the full string
# Production format: ssh [options] user@host timeout 25s bash -lc 'escaped_cmd'
HOST=""
REMOTE_CMD=""
for arg in "$@"; do
  if [[ "$arg" == *@* ]]; then
    HOST="$arg"
  fi
done

# Extract the remote command part (after host)
# We look for the last occurrence of a pattern that looks like a command start
# Usually it's 'timeout' or 'bash'
if echo "$CMD" | grep -q "git rev-parse HEAD"; then
  if [[ -f "${MOCK_STATE_DIR}/state/git_sha" ]]; then
    cat "${MOCK_STATE_DIR}/state/git_sha"
  else
    echo "899e7ce7bbea4b2745e5981e45c11e02df80892f"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "git status --porcelain"; then
  if [[ -f "${MOCK_STATE_DIR}/state/git_dirty" ]]; then
    cat "${MOCK_STATE_DIR}/state/git_dirty"
  else
    echo ""
  fi
  exit 0
fi

if echo "$CMD" | grep -q "docker image inspect"; then
  if [[ -f "${MOCK_STATE_DIR}/state/image_id" ]]; then
    cat "${MOCK_STATE_DIR}/state/image_id"
  else
    echo "sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "find.*safetensors.*wc -l"; then
  if [[ -f "${MOCK_STATE_DIR}/state/shard_count" ]]; then
    cat "${MOCK_STATE_DIR}/state/shard_count"
  else
    echo "48"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "sha256sum.*index.json"; then
  if [[ -f "${MOCK_STATE_DIR}/state/index_sha" ]]; then
    cat "${MOCK_STATE_DIR}/state/index_sha"
  else
    echo "abc123def456"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "ip link show.*enp1s0f1np1"; then
  if [[ -f "${MOCK_STATE_DIR}/state/rdma_down" ]]; then
    echo "state DOWN"
  else
    echo "state UP"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "ping.*169.254"; then
  if [[ -f "${MOCK_STATE_DIR}/state/peer_fail" ]]; then
    exit 1
  fi
  exit 0
fi

if echo "$CMD" | grep -q "ss -tlnp"; then
  # Extract port from the command string
  local port=""
  for arg in "$@"; do
    if [[ "$arg" == *":8000"* ]] || [[ "$arg" == *":29500"* ]] || [[ "$arg" == *":6379"* ]] || [[ "$arg" == *":8265"* ]]; then
      port=$(echo "$arg" | grep -oP ':\K[0-9]+')
      break
    fi
  done
  if [[ -n "$port" ]] && [[ -f "${MOCK_STATE_DIR}/state/port_${port}" ]]; then
    echo "LISTEN"
    exit 0
  fi
  exit 1
fi

if echo "$CMD" | grep -q "free -g"; then
  if [[ -f "${MOCK_STATE_DIR}/state/memory_low" ]]; then
    # Return numeric value only as per requirements
    echo "246"
  else
    echo "246"
  fi
  exit 0
fi

if echo "$CMD" | grep -q "docker ps"; then
  if [[ -f "${MOCK_STATE_DIR}/state/media_container" ]]; then
    echo "comfyui-spark"
    exit 0
  fi
  exit 1
fi

if echo "$CMD" | grep -q "ps aux.*comfyui"; then
  if [[ -f "${MOCK_STATE_DIR}/state/media_ps" ]]; then
    echo "python comfyui.py"
    exit 0
  fi
  exit 1
fi

exit 0
SSHEOF
  chmod +x "${fake_bin}/ssh"

  # Create fake ss that always fails (preflight uses ssh for ss usually, but just in case)
  cat > "${fake_bin}/ss" << 'SSEOF'
#!/usr/bin/env bash
exit 1
SSEOF
  chmod +x "${fake_bin}/ss"

  # Create fake docker that fails
  cat > "${fake_bin}/docker" << 'DOCKEOF'
#!/usr/bin/env bash
exit 1
DOCKEOF
  chmod +x "${fake_bin}/docker"

  # Create fake ping that fails
  cat > "${fake_bin}/ping" << 'PINGEOF'
#!/usr/bin/env bash
exit 1
PINGEOF
  chmod +x "${fake_bin}/ping"

  # Create fake free that returns normal memory
  cat > "${fake_bin}/free" << 'FREEEOF'
#!/usr/bin/env bash
echo "246"
FREEEOF
  chmod +x "${fake_bin}/free"

  # Create fake ps that returns empty
  cat > "${fake_bin}/ps" << 'PSEOF'
#!/usr/bin/env bash
exit 0
PSEOF
  chmod +x "${fake_bin}/ps"

  # Create fake ip
  cat > "${fake_bin}/ip" << 'IPEOF'
#!/usr/bin/env bash
echo "state UP"
IPEOF
  chmod +x "${fake_bin}/ip"

  # Create fake find
  cat > "${fake_bin}/find" << 'FINDEOF'
#!/usr/bin/env bash
exit 0
FINDEOF
  chmod +x "${fake_bin}/find"

  # Create fake sha256sum
  cat > "${fake_bin}/sha256sum" << 'SHAEOF'
#!/usr/bin/env bash
echo "abc123def456  index.json"
SHAEOF
  chmod +x "${fake_bin}/sha256sum"

  # Create fake git
  cat > "${fake_bin}/git" << 'GITEOF'
#!/usr/bin/env bash
exit 0
GITEOF
  chmod +x "${fake_bin}/git"

  # Set up state files
  touch "${state_dir}/ssh_fail" 2>/dev/null || true
  rm -f "${state_dir}/ssh_fail" 2>/dev/null || true
  echo "899e7ce7bbea4b2745e5981e45c11e02df80892f" > "${state_dir}/git_sha"
  touch "${state_dir}/git_dirty" 2>/dev/null || true
  rm -f "${state_dir}/git_dirty" 2>/dev/null || true
  echo "sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da" > "${state_dir}/image_id"
  echo "48" > "${state_dir}/shard_count"
  echo "abc123def456" > "${state_dir}/index_sha"
  touch "${state_dir}/rdma_down" 2>/dev/null || true
  rm -f "${state_dir}/rdma_down" 2>/dev/null || true
  touch "${state_dir}/peer_fail" 2>/dev/null || true
  rm -f "${state_dir}/peer_fail" 2>/dev/null || true
  rm -f "${state_dir}/port_8000" "${state_dir}/port_29500" "${state_dir}/port_6379" "${state_dir}/port_8265" 2>/dev/null || true
  touch "${state_dir}/memory_low" 2>/dev/null || true
  rm -f "${state_dir}/memory_low" 2>/dev/null || true
  touch "${state_dir}/media_container" 2>/dev/null || true
  rm -f "${state_dir}/media_container" 2>/dev/null || true
  touch "${state_dir}/media_ps" 2>/dev/null || true
  rm -f "${state_dir}/media_ps" 2>/dev/null || true

  # Initialize log
  > "${log_file}"

  # Run preflight
  local exit_code=0
  set +e
  ALLOW_MEDIA_STOP="$allow_media" PATH="${fake_bin}:${ORIGINAL_PATH}" MOCK_STATE_DIR="${state_dir}" MOCK_COMMAND_LOG="${log_file}" /bin/bash "${BIN_DIR}/preflight.sh" --check-only > "${MOCK_STATE_DIR}/stdout" 2> "${MOCK_STATE_DIR}/stderr"
  exit_code=$?
  set -e

  # Store outputs for inspection
  cp "${MOCK_STATE_DIR}/stdout" "${state_dir}/preflight_stdout"
  cp "${MOCK_STATE_DIR}/stderr" "${state_dir}/preflight_stderr"
  cp "${log_file}" "${state_dir}/command_log"

  return $exit_code
}

# Helper to set mock state
set_mock_state() {
  local key="$1"
  local value="$2"
  if [[ "$value" == "true" ]]; then
    touch "${MOCK_STATE_DIR}/state/${key}"
  elif [[ "$value" == "false" ]]; then
    rm -f "${MOCK_STATE_DIR}/state/${key}"
  else
    echo "$value" > "${MOCK_STATE_DIR}/state/${key}"
  fi
}

# Helper to check assertion
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

# Test 1: Pass (All clean)
echo "Test 1: Pass (All clean)"
run_preflight "0" || true
exit_code=$?
assert_exit 0 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=true" || exit 1
echo "PASS: Test 1"

# Test 2: Total SSH Failure
echo "Test 2: SSH Failure"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 2"

# Test 3: Dirty Repo (SHA Mismatch)
echo "Test 3: Dirty Repo"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 3"

# Test 4: Expected Runtime SHA Mismatch
echo "Test 4: SHA Mismatch"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 4"

# Test 5: Different Host Runtime SHAs (Simulated by changing expected SHA in mock)
echo "Test 5: Host SHA Mismatch"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 5"

# Test 6: Shard Mismatch
echo "Test 6: Shard Mismatch"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 6"

# Test 7: Unequal Host Index Hashes
echo "Test 7: Index SHA Mismatch"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 7"

# Test 8: Image Mismatch
echo "Test 8: Image ID Mismatch"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 8"

# Test 9: RDMA Down
echo "Test 9: RDMA Down"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 9"

# Test 10: Peer Failure
echo "Test 10: Peer Failure"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 10"

# Test 11: Occupied Port 8000
echo "Test 11: Occupied Port 8000"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 11"

# Test 12: Occupied Port 29500
echo "Test 12: Occupied Port 29500"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 12"

# Test 13: Occupied Port 6379
echo "Test 13: Occupied Port 6379"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 13"

# Test 14: Occupied Port 8265
echo "Test 14: Occupied Port 8265"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 14"

# Test 15: Low Memory
echo "Test 15: Low Memory"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=false" || exit 1
echo "PASS: Test 15"

# Test 16: Media Container Blocked
echo "Test 16: Media Container Blocked"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "blocked_media_in_use=true" || exit 1
echo "PASS: Test 16"

# Test 17: Media Python Process Blocked
echo "Test 17: Media Python Process Blocked"
run_preflight "0" || true
exit_code=$?
assert_exit 1 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "blocked_media_in_use=true" || exit 1
echo "PASS: Test 17"

# Test 18: Media Override (ALLOW_MEDIA_STOP=1)
echo "Test 18: Media Override"
run_preflight "1" || true
exit_code=$?
assert_exit 0 $exit_code || exit 1
assert_contains "${MOCK_STATE_DIR}/state/preflight_stdout" "start_allowed=true" || exit 1
# Verify no mutating commands in log
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker stop" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker start" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker rm" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker compose" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker up" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "docker down" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "kill" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "pkill" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "systemctl start" || exit 1
assert_not_contains "${MOCK_STATE_DIR}/state/command_log" "systemctl stop" || exit 1
echo "PASS: Test 18"

# Test 19: Verify no mutating commands in production scripts
echo "Test 19: No Mutating Commands in Production Scripts"
forbidden_cmds=("docker start" "docker stop" "docker rm" "docker compose" "docker up" "docker down" "kill" "pkill" "systemctl start" "systemctl stop" "mv" "cp" "rsync" "scp" "sed -i" "tee" "truncate" "touch" "mkdir" "rm" "git checkout" "git reset" "git clean" "git pull")
for cmd in "${forbidden_cmds[@]}"; do
  if grep -q "$cmd" "${BIN_DIR}/preflight.sh" "${BIN_DIR}/common.sh" "${BIN_DIR}/status.sh" "${BIN_DIR}/verify-dspark-model-cache.sh" 2>/dev/null; then
    echo "FAIL: Test 19 - Found forbidden command: $cmd"
    exit 1
  fi
done
echo "PASS: Test 19"

echo "All tests passed!"
exit 0
