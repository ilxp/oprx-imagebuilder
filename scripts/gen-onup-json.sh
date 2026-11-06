#!/usr/bin/env bash
# ==============================================================================
# gen-onup-json.sh —— 生成 onup 在线升级用的 oR.json
#
# 用法:
#   gen-onup-json.sh \
#     --fw-file    /path/to/OprX-xxx.img.gz \
#     --out        /path/to/oR.json \
#     --profile    x86_64 \
#     --re-url     "https://github.com/user/repo/releases/download/firmware" \
#     --build-date 2026110214 \
#     [--logs      /path/to/CHANGELOG.md]
#
# 输出（若 --out 已存在且含其他 profile，会合并）:
#   {
#     "x86_64": [{"build_date":"...","name":"...","re_url":"...","size":N,"sha256sum":"...","logs":"..."}]
#   }
# ==============================================================================
set -euo pipefail

FW_FILE=""; OUT=""; PROFILE=""; RE_URL=""; BUILD_DATE=""; LOGS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fw-file)    FW_FILE="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --profile)    PROFILE="$2"; shift 2 ;;
    --re-url)     RE_URL="$2"; shift 2 ;;
    --build-date) BUILD_DATE="$2"; shift 2 ;;
    --logs)       LOGS_FILE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$FW_FILE" ]] || { echo "固件不存在: $FW_FILE" >&2; exit 1; }
[[ -n "$PROFILE" ]] || { echo "--profile 必填" >&2; exit 1; }
[[ -n "$RE_URL" ]]  || { echo "--re-url 必填" >&2; exit 1; }
[[ -n "$OUT" ]]     || { echo "--out 必填" >&2; exit 1; }

BUILD_DATE="${BUILD_DATE:-$(TZ=Asia/Shanghai date +%Y%m%d%H)}"

NAME=$(basename "$FW_FILE")
SIZE=$(stat -c%s "$FW_FILE")
SHA=$(sha256sum "$FW_FILE" | cut -d' ' -f1)

mkdir -p "$(dirname "$OUT")"

# 通过环境变量传给 python，避免引号地狱
export OUT FW_FILE_NAME="$NAME" FW_SIZE="$SIZE" FW_SHA="$SHA" \
       FW_DATE="$BUILD_DATE" FW_RE_URL="$RE_URL" FW_PROFILE="$PROFILE" \
       FW_LOGS_FILE="${LOGS_FILE:-}"

python3 <<'PYEOF'
import json, os, sys

entry = {
    "build_date": os.environ["FW_DATE"],
    "name":       os.environ["FW_FILE_NAME"],
    "re_url":     os.environ["FW_RE_URL"],
    "size":       int(os.environ["FW_SIZE"]),
    "sha256sum":  os.environ["FW_SHA"],
    "logs":       "",
}

logs_path = os.environ.get("FW_LOGS_FILE", "")
if logs_path and os.path.isfile(logs_path):
    with open(logs_path, encoding="utf-8") as f:
        entry["logs"] = f.read()

profile = os.environ["FW_PROFILE"]
out_path = os.environ["OUT"]

# 合并已有 JSON（多 target 并行构建时各写各的 profile）
data = {}
if os.path.isfile(out_path) and os.path.getsize(out_path) > 0:
    try:
        with open(out_path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"警告: {out_path} 解析失败，忽略: {e}", file=sys.stderr)
        data = {}

# 同一 profile 只保留最新一条
data[profile] = [entry]

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"  oR.json: {out_path}  ({len(data)} 个 profile: {', '.join(sorted(data))})")
PYEOF