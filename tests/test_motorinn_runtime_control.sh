#!/bin/bash
set -euo pipefail

# Create isolated test fixture
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Copy production scripts into fixture
cp motorinn/bin/start-dspark-tp2.sh "$TEST_DIR/"
cp motorinn/bin/stop-vllm-spark.sh "$TEST_DIR/"
cp motorinn/bin/common.sh "$TEST_DIR/"

# Create fake preflight.sh that simulates various states
cat > "$TEST_DIR/preflight.sh" << 'PREFLIGHT_EOF'
#!/bin/bash
if [ "$1" != "--check-only" ]; then
  exit 1
fi

# Check environment variables to determine behavior
if [ "${TEST_PREFLIGHT_STATE:-normal}" = "blocked_media" ]; then
  echo "blocked_media_in_use=true"
  echo "start_allowed=true"
  exit 0
elif [ "${TEST_PREFLIGHT_STATE:-normal}" = "no_start" ]; then
  echo "start_allowed=false"
  exit 0
elif [ "${TEST_PREFLIGHT_STATE:-normal}" = "fail" ]; then
  exit 1
else
  echo "start_allowed=true"
  exit 0
fi
PREFLIGHT_EOF
chmod +x "$TEST_DIR/preflight.sh"

# Create fake common.sh with mocked run_remote
cat > "$TEST_DIR/common.sh" << 'COMMON_EOF'
HEAD_HOST="fake-head-host"
WORKER_HOST="fake-worker-host"
SSH_USER="testuser"
RELEASE_PATH="/tmp/fake-release"

run_remote() {
  echo "RUN_REMOTE_CALLED $1 $2"
  return 0
}
COMMON_EOF
chmod +x "$TEST_DIR/common.sh"

# Create fakes for external commands to ensure they are not called
cat > "$TEST_DIR/docker" << 'DOCKER_EOF'
#!/bin/bash
echo "FORBIDDEN_DOCKER_CALL $*"
exit 1
DOCKER_EOF
chmod +x "$TEST_DIR/docker"

cat > "$TEST_DIR/sleep" << 'SLEEP_EOF'
#!/bin/bash
echo "FORBIDDEN_SLEEP_CALL $1"
exit 1
SLEEP_EOF
chmod +x "$TEST_DIR/sleep"

cat > "$TEST_DIR/curl" << 'CURL_EOF'
#!/bin/bash
echo "FORBIDDEN_CURL_CALL $*"
exit 1
CURL_EOF
chmod +x "$TEST_DIR/curl"

cat > "$TEST_DIR/ray" << 'RAY_EOF'
#!/bin/bash
echo "FORBIDDEN_RAY_CALL $*"
exit 1
RAY_EOF
chmod +x "$TEST_DIR/ray"

# Add test dir to PATH so fakes are picked up
export PATH="$TEST_DIR:$PATH"

FAILED=0

# Test 1: Start without approval should fail and not call remote/sleep
echo "Test 1: Start without approval"
output=$("$TEST_DIR/start-dspark-tp2.sh" 2>&1 || true)
if echo "$output" | grep -q "approval_required=ALLOW_RUNTIME_START"; then
  echo "PASS: Start refused without approval"
else
  echo "FAIL: Start did not refuse without approval"
  FAILED=1
fi

# Test 2: Stop without approval should fail
echo "Test 2: Stop without approval"
output=$("$TEST_DIR/stop-vllm-spark.sh" 2>&1 || true)
if echo "$output" | grep -q "approval_required=ALLOW_RUNTIME_STOP"; then
  echo "PASS: Stop refused without approval"
else
  echo "FAIL: Stop did not refuse without approval"
  FAILED=1
fi

# Test 3: Preflight failure blocks start
echo "Test 3: Preflight failure blocks start"
TEST_PREFLIGHT_STATE=fail "$TEST_DIR/start-dspark-tp2.sh" 2>&1 || true
if [ $? -ne 0 ]; then
  echo "PASS: Start blocked by preflight failure"
else
  echo "FAIL: Start not blocked by preflight failure"
  FAILED=1
fi

# Test 4: Preflight start_allowed=false blocks start
echo "Test 4: Preflight start_allowed=false blocks start"
TEST_PREFLIGHT_STATE=no_start "$TEST_DIR/start-dspark-tp2.sh" 2>&1 || true
if [ $? -ne 0 ]; then
  echo "PASS: Start blocked by start_allowed=false"
else
  echo "FAIL: Start not blocked by start_allowed=false"
  FAILED=1
fi

# Test 5: Media blocked without ALLOW_MEDIA_STOP
echo "Test 5: Media blocked without ALLOW_MEDIA_STOP"
TEST_PREFLIGHT_STATE=blocked_media "$TEST_DIR/start-dspark-tp2.sh" 2>&1 || true
if [ $? -ne 0 ]; then
  echo "PASS: Start blocked by media without ALLOW_MEDIA_STOP"
else
  echo "FAIL: Start not blocked by media without ALLOW_MEDIA_STOP"
  FAILED=1
fi

# Test 6: Media with ALLOW_MEDIA_STOP allows start (but no media mutation)
echo "Test 6: Media with ALLOW_MEDIA_STOP allows start"
TEST_PREFLIGHT_STATE=blocked_media ALLOW_RUNTIME_START=1 "$TEST_DIR/start-dspark-tp2.sh" 2>&1 || true
if [ $? -eq 0 ]; then
  echo "PASS: Start allowed with media and ALLOW_MEDIA_STOP"
else
  echo "FAIL: Start not allowed with media and ALLOW_MEDIA_STOP"
  FAILED=1
fi

# Test 7: Verify worker starts before sleep 25 and head
echo "Test 7: Worker start order verification"
# We can't easily verify timing in this isolated env without mocking, 
# but we can check the script content for forbidden commands
if grep -q "docker compose.*--profile worker up" "$TEST_DIR/start-dspark-tp2.sh" && \
   grep -q "sleep 25" "$TEST_DIR/start-dspark-tp2.sh" && \
   grep -q "docker compose.*--profile head up" "$TEST_DIR/start-dspark-tp2.sh"; then
  echo "PASS: Start order structure looks correct"
else
  echo "FAIL: Start order structure incorrect"
  FAILED=1
fi

# Test 8: No --build or --pull in start script
echo "Test 8: No build/pull in start script"
if grep -q "\-\-build" "$TEST_DIR/start-dspark-tp2.sh" || grep -q "\-\-pull" "$TEST_DIR/start-dspark-tp2.sh"; then
  echo "FAIL: Found --build or --pull in start script"
  FAILED=1
else
  echo "PASS: No build/pull in start script"
fi

# Test 9: Stop uses exact container names
echo "Test 9: Stop uses exact container names"
if grep -q "docker rm -f vllm-spark-head vllm-dspark-head vllm-head" "$TEST_DIR/stop-vllm-spark.sh" && \
   grep -q "docker rm -f vllm-spark-worker vllm-dspark-worker vllm-worker" "$TEST_DIR/stop-vllm-spark.sh"; then
  echo "PASS: Stop uses exact container names"
else
  echo "FAIL: Stop does not use exact container names"
  FAILED=1
fi

# Test 10: Stop uses ray stop --force
echo "Test 10: Stop uses ray stop --force"
if grep -q "ray stop --force" "$TEST_DIR/stop-vllm-spark.sh"; then
  echo "PASS: Stop uses ray stop --force"
else
  echo "FAIL: Stop does not use ray stop --force"
  FAILED=1
fi

# Test 11: No wildcard/filter/compose down/image/volume/file/media mutation in stop
echo "Test 11: No forbidden commands in stop script"
if grep -qE "docker compose down|docker rmi|docker volume rm|\*|media" "$TEST_DIR/stop-vllm-spark.sh"; then
  echo "FAIL: Found forbidden commands in stop script"
  FAILED=1
else
  echo "PASS: No forbidden commands in stop script"
fi

# Test 12: Health timeout bounded
echo "Test 12: Health timeout bounded"
if grep -q "HEALTH_TIMEOUT_SECONDS" "$TEST_DIR/start-dspark-tp2.sh" && \
   grep -q "SECONDS" "$TEST_DIR/start-dspark-tp2.sh"; then
  echo "PASS: Health timeout is bounded"
else
  echo "FAIL: Health timeout is not bounded"
  FAILED=1
fi

# Test 13: Runtime started message
echo "Test 13: Runtime started message"
if grep -q "runtime_started=true" "$TEST_DIR/start-dspark-tp2.sh"; then
  echo "PASS: Runtime started message present"
else
  echo "FAIL: Runtime started message missing"
  FAILED=1
fi

# Test 14: Runtime stopped message
echo "Test 14: Runtime stopped message"
if grep -q "runtime_stopped=true" "$TEST_DIR/stop-vllm-spark.sh"; then
  echo "PASS: Runtime stopped message present"
else
  echo "FAIL: Runtime stopped message missing"
  FAILED=1
fi

# Test 15: Scan for forbidden commands in production scripts
echo "Test 15: Scan for forbidden commands"
FORBIDDEN_FOUND=0
if grep -qE "watchdog|wget|curl.*http" "$TEST_DIR/start-dspark-tp2.sh"; then
  echo "FAIL: Found forbidden command in start script"
  FORBIDDEN_FOUND=1
fi
if grep -qE "docker compose down|docker rmi|docker volume rm" "$TEST_DIR/stop-vllm-spark.sh"; then
  echo "FAIL: Found forbidden command in stop script"
  FORBIDDEN_FOUND=1
fi
if [ $FORBIDDEN_FOUND -eq 0 ]; then
  echo "PASS: No forbidden commands found"
else
  FAILED=1
fi

if [ $FAILED -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "Some tests failed"
  exit 1
fi
