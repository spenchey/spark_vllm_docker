#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

printf '%s\n' '=== Integrated Motor Inn Spark runtime proof ==='

while IFS= read -r shell_file; do
  /bin/bash -n "$shell_file" || fail "shell syntax: $shell_file"
done < <(find motorinn/bin -maxdepth 1 -type f -name '*.sh' -print | sort)

for shell_file in \
  tests/test_motorinn_runtime_config.sh \
  tests/test_motorinn_preflight.sh \
  tests/test_motorinn_runtime_control.sh \
  tests/test_motorinn_runtime.sh; do
  /bin/bash -n "$shell_file" || fail "shell syntax: $shell_file"
done
printf '%s\n' 'PASS: all runtime shell files parse'

for entrypoint in \
  motorinn/bin/preflight.sh \
  motorinn/bin/start-dspark-tp2.sh \
  motorinn/bin/status.sh \
  motorinn/bin/stop-vllm-spark.sh \
  motorinn/bin/verify-dspark-model-cache.sh; do
  [ -x "$entrypoint" ] || fail "runtime entrypoint is not executable: $entrypoint"
done
printf '%s\n' 'PASS: all runtime entrypoints are executable'

if grep -RniE '^[[:space:]]*(export[[:space:]]+)?[A-Z_][A-Z0-9_]*(TOKEN|PASSWORD|SECRET|API_KEY|AUTHORIZATION|PRIVATE_KEY)=' motorinn/env; then
  fail 'secret-like key found in motorinn/env'
fi
printf '%s\n' 'PASS: no secret-like environment keys'

if EXPECTED_RUNTIME_SHA= REMOTE_REPO=/tmp/factory-release /bin/bash -c 'source motorinn/bin/common.sh' >/dev/null 2>&1; then
  fail 'common.sh accepted an empty EXPECTED_RUNTIME_SHA'
fi
printf '%s\n' 'PASS: runtime SHA is mandatory'

path_output=$(EXPECTED_RUNTIME_SHA=abc123 REMOTE_REPO=/tmp/factory-release /bin/bash -c 'source motorinn/bin/common.sh; printf "%s\n%s\n" "$REMOTE_REPO" "$RELEASE_PATH"')
if [ "$path_output" != $'/tmp/factory-release\n/tmp/factory-release' ]; then
  fail 'REMOTE_REPO did not control RELEASE_PATH'
fi
printf '%s\n' 'PASS: REMOTE_REPO is the release path'

/bin/bash tests/test_motorinn_runtime_config.sh
/bin/bash tests/test_motorinn_preflight.sh
/bin/bash tests/test_motorinn_runtime_control.sh

printf '%s\n' 'All integrated Motor Inn Spark runtime tests passed'
