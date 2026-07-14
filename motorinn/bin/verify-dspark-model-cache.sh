#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${1:-/home/spenchey/models/huggingface/deepseek-ai__DeepSeek-V4-Flash-DSpark}"
EXPECTED_SHARDS="${EXPECTED_SHARDS:-48}"

python3 - "${MODEL_DIR}" "${EXPECTED_SHARDS}" <<'PY'
import json
import pathlib
import sys

model_dir = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
index_path = model_dir / "model.safetensors.index.json"

if not index_path.exists():
    raise SystemExit(f"missing {index_path}")

data = json.loads(index_path.read_text())
weight_map = data.get("weight_map")
if not isinstance(weight_map, dict):
    raise SystemExit(f"{index_path} has no weight_map")

shards = sorted(set(weight_map.values()))
missing = [name for name in shards if not (model_dir / name).is_file()]
if len(shards) != expected:
    raise SystemExit(f"expected {expected} safetensor shards, found {len(shards)}")
if missing:
    raise SystemExit("missing safetensor shard(s): " + ", ".join(missing[:10]))

config = model_dir / "config.json"
if not config.exists():
    raise SystemExit(f"missing {config}")

print(f"model cache ok: {len(shards)} safetensor shards, 0 missing")
PY

