#!/usr/bin/env bash
# test_motorinn_preflight.sh - Regression tests for MOT-2457 preflight
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/../motorinn/bin"

echo "Running MOT-2457 Preflight Tests..."

# Helper to run preflight with mocked environment
run_preflight() {
  local env_vars="$1"
  shift
  
  # Create isolated temporary fixture
  local tmp_dir=$(mktemp -d)
  
  # Create mock commands directory
  mkdir -p "${tmp_dir}/bin"
  
  # Mock SSH to simulate success/failure based on args
  cat > "${tmp_dir}/bin/ssh" << 'EOF'
#!/usr/bin/env bash
# Mock SSH
if [[ -f /tmp/mock_ssh_fail ]]; then
  exit 1
fi

local cmd="$*"

# Simulate git rev-parse HEAD
if echo "$cmd" | grep -q "git rev-parse HEAD"; then
  if [[ -f /tmp/mock_git_sha ]]; then
    cat /tmp/mock_git_sha
  else
    echo "899e7ce7bbea4b2745e5981e45c11e02df80892f"
  fi
  exit 0
fi

# Simulate git status --porcelain
if echo "$cmd" | grep -q "git status --porcelain"; then
  if [[ -f /tmp/mock_git_dirty ]]; then
    cat /tmp/mock_git_dirty
  else
    echo ""
  fi
  exit 0
fi

# Simulate docker inspect
if echo "$cmd" | grep -q "docker inspect"; then
  if [[ -f /tmp/mock_image_id ]]; then
    cat /tmp/mock_image_id
  else
    echo "sha256:85e1650f6c5cf0d694896f1085b24b585412cdd60d2b93d310d48b9f20a986da"
  fi
  exit 0
fi

# Simulate find shards
if echo "$cmd" | grep -q "find.*safetensors.*wc -l"; then
  if [[ -f /tmp/mock_shard_count ]]; then
    cat /tmp/mock_shard_count
  else
    echo "48"
  fi
  exit 0
fi

# Simulate sha256sum index
if echo "$cmd" | grep -q "sha256sum.*index.json"; then
  if [[ -f /tmp/mock_index_sha ]]; then
    cat /tmp/mock_index_sha
  else
    echo "abc123def456"
  fi
  exit 0
fi

# Simulate ip link show RDMA
if echo "$cmd" | grep -q "ip link show.*enp1s0f1np1"; then
  if [[ -f /tmp/mock_rdma_down ]]; then
    echo "state DOWN"
  else
    echo "state UP"
  fi
  exit 0
fi

# Simulate ping peer
if echo "$cmd" | grep -q "ping.*169.254"; then
  if [[ -f /tmp/mock_peer_fail ]]; then
    exit 1
  fi
  exit 0
fi

# Simulate ss port check
if echo "$cmd" | grep -q "ss -tlnp"; then
  local port=$(echo "$cmd" | grep -oP ':\K[0-9]+')
  if [[ -f "/tmp/mock_port_${port}" ]]; then
    echo "LISTEN"
    exit 0
  fi
  exit 1
fi

# Simulate free -g (provide numeric seventh field)
if echo "$cmd" | grep -q "free -g"; then
  if [[ -f /tmp/mock_memory_low ]]; then
    echo "Mem:       50G          10G         40G         0G        50G"
  else
    echo "Mem:      256G         10G        246G         0G       246G"
  fi
  exit 0
fi

# Simulate docker ps for media check
if echo "$cmd" | grep -q "docker ps"; then
  if [[ -f /tmp/mock_media ]]; then
    echo "comfyui-spark"
    exit 0
  fi
  exit 1
fi

# Simulate ps aux for media check
if echo "$cmd" | grep -q "ps aux.*comfyui"; then
  if [[ -f /tmp/mock_media_ps ]]; then
    echo "python comfyui.py"
    exit 0
  fi
  exit 1
fi

exit 0
EOF
  chmod +x "${tmp_dir}/bin/ssh"

  # Mock ss
  cat > "${tmp_dir}/bin/ss" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${tmp_dir}/bin/ss"

  # Add tmp bin to PATH
  export PATH="${tmp_dir}/bin:${PATH}"

  # Run preflight with provided env vars
  eval "$env_vars" bash "${BIN_DIR}/preflight.sh" --check-only 2>&1
  local exit_code=$?
  
  # Cleanup
  rm -rf "${tmp_dir}"
  return $exit_code
}

# Helper to set mock state
set_mock() {
  local key="$1"
  local value="$2"
  if [[ "$value" == "true" ]]; then
    touch "/tmp/mock_${key}"
  elif [[ "$value" == "false" ]]; then
    rm -f "/tmp/mock_${key}"
  else
    echo "$value" > "/tmp/mock_${key}"
  fi
}

cleanup_mocks() {
  rm -f /tmp/mock_*
}

# Test 1: Pass (All clean)
echo "Test 1: Pass (All clean)"
cleanup_mocks
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=true"; then
  echo "PASS: Test 1"
else
  echo "FAIL: Test 1 - Expected start_allowed=true"
  echo "$output"
  exit 1
fi

# Test 2: SSH Failure (Dirty)
echo "Test 2: SSH Failure"
cleanup_mocks
touch /tmp/mock_ssh_fail
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 2"
else
  echo "FAIL: Test 2 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 3: Dirty Repo (SHA Mismatch)
echo "Test 3: Dirty Repo"
cleanup_mocks
echo "badsha" > /tmp/mock_git_sha
echo " M file.txt" > /tmp/mock_git_dirty
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 3"
else
  echo "FAIL: Test 3 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 4: Shard Mismatch
echo "Test 4: Shard Mismatch"
cleanup_mocks
echo "47" > /tmp/mock_shard_count
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 4"
else
  echo "FAIL: Test 4 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 5: Index SHA Mismatch
echo "Test 5: Index SHA Mismatch"
cleanup_mocks
echo "badindex" > /tmp/mock_index_sha
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 5"
else
  echo "FAIL: Test 5 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 6: Image ID Mismatch
echo "Test 6: Image ID Mismatch"
cleanup_mocks
echo "sha256:badimage" > /tmp/mock_image_id
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 6"
else
  echo "FAIL: Test 6 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 7: RDMA Down
echo "Test 7: RDMA Down"
cleanup_mocks
touch /tmp/mock_rdma_down
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 7"
else
  echo "FAIL: Test 7 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 8: Peer Failure
echo "Test 8: Peer Failure"
cleanup_mocks
touch /tmp/mock_peer_fail
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 8"
else
  echo "FAIL: Test 8 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 9: Occupied Port
echo "Test 9: Occupied Port"
cleanup_mocks
touch /tmp/mock_port_8000
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 9"
else
  echo "FAIL: Test 9 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 10: Low Memory
echo "Test 10: Low Memory"
cleanup_mocks
touch /tmp/mock_memory_low
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 10"
else
  echo "FAIL: Test 10 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 11: Media Blocked
echo "Test 11: Media Blocked"
cleanup_mocks
touch /tmp/mock_media
output=$(run_preflight "export ALLOW_MEDIA_STOP=0") || true
if echo "$output" | grep -q "start_allowed=false"; then
  echo "PASS: Test 11"
else
  echo "FAIL: Test 11 - Expected start_allowed=false"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 12: Media Override (ALLOW_MEDIA_STOP=1) but still no stop
echo "Test 12: Media Override"
cleanup_mocks
touch /tmp/mock_media
output=$(run_preflight "export ALLOW_MEDIA_STOP=1") || true
if echo "$output" | grep -q "start_allowed=true"; then
  echo "PASS: Test 12"
else
  echo "FAIL: Test 12 - Expected start_allowed=true with ALLOW_MEDIA_STOP=1"
  echo "$output"
  exit 1
fi
cleanup_mocks

# Test 13: Verify no mutating commands are invoked (Check script content)
echo "Test 13: No Mutating Commands"
for forbidden in "docker start" "docker stop" "docker rm" "docker compose" "docker up" "docker down" "kill" "pkill" "systemctl start" "systemctl stop" "mv" "cp" "rsync" "scp" "sed -i" "tee" "truncate" "touch" "mkdir" "rm" "git checkout" "git reset" "git clean" "git pull" ">"; do
  if grep -q "$forbidden" "${BIN_DIR}/preflight.sh" "${BIN_DIR}/common.sh" "${BIN_DIR}/status.sh" "${BIN_DIR}/verify-dspark-model-cache.sh"; then
    echo "FAIL: Test 13 - Found forbidden command: $forbidden"
    exit 1
  fi
done
echo "PASS: Test 13"

echo "All tests passed!"
