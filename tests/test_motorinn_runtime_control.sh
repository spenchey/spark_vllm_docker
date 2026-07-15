#!/bin/bash
set -euo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"
FAKE="$ROOT/fake"
CALL_LOG="$ROOT/calls.log"
OUTPUT="$ROOT/output.log"
mkdir -p "$BIN" "$FAKE"

cp motorinn/bin/start-dspark-tp2.sh "$BIN/"
cp motorinn/bin/stop-vllm-spark.sh "$BIN/"
cp motorinn/bin/common.sh "$BIN/"
chmod +x "$BIN/start-dspark-tp2.sh" "$BIN/stop-vllm-spark.sh"

cat > "$BIN/preflight.sh" <<'EOF'
#!/bin/bash
printf 'preflight|%s\n' "$*" >> "$CALL_LOG"
case "${TEST_PREFLIGHT_STATE:-pass}" in
  fail) exit 1 ;;
  no_start) printf 'start_allowed=false\n'; exit 0 ;;
  media) printf 'blocked_media_in_use=true\nstart_allowed=true\n'; exit 0 ;;
  pass) printf 'start_allowed=true\n'; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/preflight.sh"

cat > "$BIN/common.sh" <<'EOF'
HEAD_HOST="fake-head-host"
WORKER_HOST="fake-worker-host"
RELEASE_PATH="/tmp/fake-release"
RUNTIME_PORT="8888"
run_remote() {
  printf 'remote|%s|%s\n' "$1" "$2" >> "$CALL_LOG"
  case "$2" in
    *"--profile worker up -d worker"*)
      [ "${TEST_REMOTE_FAILURE:-}" != "worker_start" ]
      ;;
    *"--profile head up -d head"*)
      [ "${TEST_REMOTE_FAILURE:-}" != "head_start" ]
      ;;
    *"curl -fsS --max-time 5 http://127.0.0.1:8888/health"*)
      [ "${TEST_HEALTH_STATE:-success}" = "success" ]
      ;;
    *"vllm-spark-head vllm-dspark-head vllm-head"*)
      [ "${TEST_REMOTE_FAILURE:-}" != "head_remove" ]
      ;;
    *"vllm-spark-worker vllm-dspark-worker vllm-worker"*)
      [ "${TEST_REMOTE_FAILURE:-}" != "worker_remove" ]
      ;;
    "ray stop --force")
      if [ "$1" = "$HEAD_HOST" ]; then
        [ "${TEST_REMOTE_FAILURE:-}" != "head_ray" ]
      else
        [ "${TEST_REMOTE_FAILURE:-}" != "worker_ray" ]
      fi
      ;;
    *) return 0 ;;
  esac
}
EOF

cat > "$FAKE/sleep" <<'EOF'
#!/bin/bash
printf 'sleep|%s\n' "$1" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE/sleep"

for command in docker curl ssh ray; do
  cat > "$FAKE/$command" <<'EOF'
#!/bin/bash
printf 'local-%s|%s\n' "$(basename "$0")" "$*" >> "$CALL_LOG"
exit 99
EOF
  chmod +x "$FAKE/$command"
done

TEST_PATH="$FAKE:$PATH"
FAILED=0
RC=0

reset_case() {
  : > "$CALL_LOG"
  : > "$OUTPUT"
}

run_script() {
  local script="$1"
  shift
  set +e
  env PATH="$TEST_PATH" CALL_LOG="$CALL_LOG" "$@" /bin/bash "$script" > "$OUTPUT" 2>&1
  RC=$?
  set -e
}

run_start_arg() {
  set +e
  env PATH="$TEST_PATH" CALL_LOG="$CALL_LOG" ALLOW_RUNTIME_START=1 /bin/bash "$BIN/start-dspark-tp2.sh" unexpected > "$OUTPUT" 2>&1
  RC=$?
  set -e
}

run_stop_arg() {
  set +e
  env PATH="$TEST_PATH" CALL_LOG="$CALL_LOG" ALLOW_RUNTIME_STOP=1 /bin/bash "$BIN/stop-vllm-spark.sh" unexpected > "$OUTPUT" 2>&1
  RC=$?
  set -e
}

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

expect_rc() {
  local expected="$1"
  local name="$2"
  if [ "$RC" -eq "$expected" ]; then pass "$name"; else fail "$name expected rc=$expected got=$RC"; fi
}

expect_output_line() {
  local expected="$1"
  local name="$2"
  if grep -qx "$expected" "$OUTPUT"; then pass "$name"; else fail "$name missing '$expected'"; fi
}

expect_log_contains() {
  local expected="$1"
  local name="$2"
  if grep -qF -- "$expected" "$CALL_LOG"; then pass "$name"; else fail "$name missing '$expected'"; fi
}

expect_log_absent() {
  local forbidden="$1"
  local name="$2"
  if grep -qF -- "$forbidden" "$CALL_LOG"; then fail "$name found '$forbidden'"; else pass "$name"; fi
}

expect_no_runtime_calls() {
  local name="$1"
  if grep -qE '^(remote|sleep|local-)' "$CALL_LOG"; then fail "$name"; else pass "$name"; fi
}

echo "Test 1: approval gates"
reset_case
run_script "$BIN/start-dspark-tp2.sh"
expect_rc 1 "start refuses without approval"
expect_output_line "approval_required=ALLOW_RUNTIME_START" "start approval message"
[ ! -s "$CALL_LOG" ] && pass "start approval before all calls" || fail "start approval called a dependency"

reset_case
run_script "$BIN/stop-vllm-spark.sh"
expect_rc 1 "stop refuses without approval"
expect_output_line "approval_required=ALLOW_RUNTIME_STOP" "stop approval message"
[ ! -s "$CALL_LOG" ] && pass "stop approval before all calls" || fail "stop approval called a dependency"

echo "Test 2: positional arguments"
reset_case
run_start_arg
expect_rc 1 "start rejects positional argument"
[ ! -s "$CALL_LOG" ] && pass "start argument rejected before calls" || fail "start argument caused calls"

reset_case
run_stop_arg
expect_rc 1 "stop rejects positional argument"
[ ! -s "$CALL_LOG" ] && pass "stop argument rejected before calls" || fail "stop argument caused calls"

echo "Test 3: preflight gates"
reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_PREFLIGHT_STATE=fail
expect_rc 1 "preflight exit blocks start"
expect_output_line "preflight_check_failed" "preflight failure message"
expect_no_runtime_calls "preflight failure has no runtime calls"

reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_PREFLIGHT_STATE=no_start
expect_rc 1 "start_allowed false blocks start"
expect_output_line "start_not_allowed" "start_not_allowed message"
expect_no_runtime_calls "start_allowed false has no runtime calls"

reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_PREFLIGHT_STATE=media
expect_rc 1 "media requires allowance"
expect_output_line "media_blocked_no_allow" "media allowance message"
expect_no_runtime_calls "media block has no runtime calls"

echo "Test 4: successful start order"
reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 ALLOW_MEDIA_STOP=1 TEST_PREFLIGHT_STATE=media TEST_HEALTH_STATE=success
expect_rc 0 "approved media-safe start succeeds"
expect_output_line "runtime_started=true" "runtime started message"
expect_log_contains "remote|fake-worker-host|cd /tmp/fake-release && docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile worker up -d worker" "exact worker start"
expect_log_contains "sleep|25" "exact worker warmup"
expect_log_contains "remote|fake-head-host|cd /tmp/fake-release && docker compose --env-file motorinn/env/deepseek-v4-flash-dspark-tp2.env --profile head up -d head" "exact head start"
expect_log_contains "remote|fake-head-host|curl -fsS --max-time 5 http://127.0.0.1:8888/health" "bounded health check"
worker_line=$(grep -nF -- "--profile worker up -d worker" "$CALL_LOG" | head -1 | cut -d: -f1)
sleep_line=$(grep -nF "sleep|25" "$CALL_LOG" | head -1 | cut -d: -f1)
head_line=$(grep -nF -- "--profile head up -d head" "$CALL_LOG" | head -1 | cut -d: -f1)
health_line=$(grep -nF "curl -fsS --max-time 5" "$CALL_LOG" | head -1 | cut -d: -f1)
if [ "$worker_line" -lt "$sleep_line" ] && [ "$sleep_line" -lt "$head_line" ] && [ "$head_line" -lt "$health_line" ]; then
  pass "worker then 25 seconds then head then health"
else
  fail "runtime order"
fi
expect_log_absent "--build" "no build"
expect_log_absent " pull" "no pull"
expect_log_absent "local-" "no local runtime tools"
expect_log_absent "comfy" "no media service named"

echo "Test 5: invalid health settings"
reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 HEALTH_TIMEOUT_SECONDS=0
expect_rc 1 "zero timeout rejected"
expect_output_line "invalid_health_timeout" "timeout validation message"
expect_no_runtime_calls "invalid timeout has no runtime calls"

reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 HEALTH_POLL_SECONDS=abc
expect_rc 1 "nonnumeric poll rejected"
expect_output_line "invalid_health_poll" "poll validation message"
expect_no_runtime_calls "invalid poll has no runtime calls"

echo "Test 6: start remote failures"
reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_REMOTE_FAILURE=worker_start
expect_rc 1 "worker start failure is fatal"
expect_log_contains "--profile worker up -d worker" "worker start was attempted"
expect_log_absent "sleep|25" "worker failure prevents warmup"
expect_log_absent "--profile head up -d head" "worker failure prevents head start"
expect_log_absent "curl -fsS" "worker failure prevents health polling"

reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_REMOTE_FAILURE=head_start
expect_rc 1 "head start failure is fatal"
expect_log_contains "--profile worker up -d worker" "worker starts before head failure"
expect_log_contains "sleep|25" "worker warmup precedes head failure"
expect_log_contains "--profile head up -d head" "head start was attempted"
expect_log_absent "curl -fsS" "head failure prevents health polling"

echo "Test 7: bounded health timeout"
reset_case
run_script "$BIN/start-dspark-tp2.sh" ALLOW_RUNTIME_START=1 TEST_HEALTH_STATE=fail HEALTH_TIMEOUT_SECONDS=1 HEALTH_POLL_SECONDS=1
expect_rc 1 "health timeout fails"
expect_output_line "health_check_timeout" "health timeout message"
expect_log_contains "remote|fake-worker-host|docker logs --tail 200 vllm-spark-worker" "worker-only log"
expect_log_contains "remote|fake-head-host|docker logs --tail 200 vllm-spark-head" "head-only log"
log_count=$(grep -cF "docker logs --tail 200" "$CALL_LOG")
[ "$log_count" -eq 2 ] && pass "exactly two timeout log commands" || fail "unexpected timeout log count $log_count"

echo "Test 8: approved safe stop"
reset_case
run_script "$BIN/stop-vllm-spark.sh" ALLOW_RUNTIME_STOP=1
expect_rc 0 "approved stop succeeds"
expect_output_line "runtime_stopped=true" "runtime stopped message"
expect_log_contains "remote|fake-head-host|command -v docker" "head exact removal command"
expect_log_contains "vllm-spark-head vllm-dspark-head vllm-head" "head allowlist"
expect_log_contains "remote|fake-worker-host|command -v docker" "worker exact removal command"
expect_log_contains "vllm-spark-worker vllm-dspark-worker vllm-worker" "worker allowlist"
expect_log_contains "remote|fake-head-host|ray stop --force" "head ray stop"
expect_log_contains "remote|fake-worker-host|ray stop --force" "worker ray stop"
remote_count=$(grep -c '^remote|' "$CALL_LOG")
[ "$remote_count" -eq 4 ] && pass "exactly four stop host operations" || fail "unexpected stop operation count $remote_count"
expect_log_absent "--filter" "no broad filter"
expect_log_absent "*" "no wildcard"
expect_log_absent "compose down" "no compose down"
expect_log_absent "docker image" "no image mutation"
expect_log_absent "docker volume" "no volume mutation"
expect_log_absent "comfy" "no media mutation"
expect_log_absent "local-" "no local stop tools"

echo "Test 9: stop remote failure"
reset_case
run_script "$BIN/stop-vllm-spark.sh" ALLOW_RUNTIME_STOP=1 TEST_REMOTE_FAILURE=head_remove
expect_rc 1 "one stop failure makes the command fail"
expect_output_line "runtime_stop_partial_failure" "partial stop failure message"
if grep -qx "runtime_stopped=true" "$OUTPUT"; then
  fail "partial failure reported full success"
else
  pass "partial failure does not report full success"
fi
remote_count=$(grep -c '^remote|' "$CALL_LOG")
[ "$remote_count" -eq 4 ] && pass "stop continues through all four operations" || fail "partial failure stopped after $remote_count operations"
expect_log_contains "vllm-spark-worker vllm-dspark-worker vllm-worker" "worker removal attempted after head failure"
expect_log_contains "remote|fake-head-host|ray stop --force" "head ray stop attempted after failure"
expect_log_contains "remote|fake-worker-host|ray stop --force" "worker ray stop attempted after failure"

echo "Test 10: production source guardrails"
if grep -Eqi 'watchdog|wget|--build|docker compose down|docker (rmi|image rm|volume rm)|--filter|comfyui' "$BIN/start-dspark-tp2.sh" "$BIN/stop-vllm-spark.sh"; then
  fail "forbidden production source"
else
  pass "production source guardrails"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed"
  exit 1
fi
echo "All runtime-control tests passed"
