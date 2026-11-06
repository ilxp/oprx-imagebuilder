#!/usr/bin/env python3
"""合并两个 oR.json（用新文件的 profile 覆盖旧文件）。

用法:
    python3 merge-onup.py <old.json> <new.json> [<output.json>]

不指定 output.json 时，结果写回 old.json。

行为:
- old.json 不存在 / 为空 / 损坏 → 直接用 new.json
- 两边都有 → old.update(new)（new 的同名 profile 覆盖 old）
- 输出：ensure_ascii=False, indent=2
"""
import json
import os
import sys


def load_json(path):
    """读 JSON，失败返回 {}（不抛异常）。"""
    if not path or not os.path.isfile(path) or os.path.getsize(path) == 0:
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"警告: {path} 解析失败，忽略: {e}", file=sys.stderr)
        return {}


def main(argv):
    if len(argv) < 3:
        print("用法: merge-onup.py <old.json> <new.json> [<output.json>]",
              file=sys.stderr)
        return 2

    old_path = argv[1]
    new_path = argv[2]
    out_path = argv[3] if len(argv) >= 4 else old_path

    old = load_json(old_path)
    new = load_json(new_path)

    if not new:
        print(f"警告: {new_path} 为空或无有效内容，不合并", file=sys.stderr)
        return 1

    old.update(new)

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(old, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"合并完成: {len(old)} 个 profile -> {', '.join(sorted(old))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))