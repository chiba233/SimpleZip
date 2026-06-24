#!/usr/bin/env bash
#
# 只对「相对 base 有改动的行」跑 SwiftLint —— 防风格漂移,且**可移植**:
# 不依赖 baseline（SwiftLint 的 baseline 存绝对路径、跨机器/CI 不可用),历史代码一行不碰,
# 只检查新增 / 改动的行。新文件视为整文件改动 → 全量受检。
#
#   scripts/lint-changed.sh [<base-ref>]
#
# 不传 base 时本地取与 origin/main(或 main)的 merge-base;CI 由 workflow 传入(PR base / push before)。
# 配置见 .swiftlint.yml。需要 swiftlint(brew install swiftlint)与一个完整 Xcode 提供 sourcekit。
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "未找到 swiftlint。安装：brew install swiftlint" >&2
  exit 127
fi

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  if git rev-parse --verify -q origin/main >/dev/null; then
    BASE="$(git merge-base origin/main HEAD)"
  elif git rev-parse --verify -q main >/dev/null; then
    BASE="$(git merge-base main HEAD)"
  else
    BASE="HEAD^"
  fi
fi

# 改动(新增/修改)的 .swift 文件;无则跳过。`while read` 而非 mapfile —— macOS 自带 bash 3.2 无 mapfile。
FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && FILES+=("$f")
done < <(git diff --name-only --diff-filter=ACM "$BASE" -- '*.swift')
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "无改动的 Swift 文件，跳过 SwiftLint。"
  exit 0
fi

DIFF="$(git diff --unified=0 "$BASE" -- '*.swift')"
JSON="$(swiftlint lint --quiet --reporter json "${FILES[@]}" 2>/dev/null || true)"

# 只保留落在「改动行」上的违规(unified=0 的 +c,d 段即新增行范围)。
DIFF="$DIFF" JSON="$JSON" python3 - <<'PY'
import json, os, re, sys

diff = os.environ["DIFF"]
js = os.environ["JSON"]

added = {}            # 相对路径 -> 新增/改动的行号集合
cur = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur = line[6:]
        added.setdefault(cur, set())
    elif line.startswith("@@") and cur is not None:
        m = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if m:
            start = int(m.group(1))
            count = int(m.group(2) or "1")
            for ln in range(start, start + count):
                added[cur].add(ln)

violations = json.loads(js) if js.strip() else []
hits = []
for v in violations:
    rel = os.path.relpath(v.get("file", ""), os.getcwd())
    line = v.get("line") or 0
    if line in added.get(rel, ()):
        hits.append((rel, line, v.get("severity", "warning"), v.get("reason", ""), v.get("rule_id", "")))

hits.sort()
for rel, line, sev, reason, rid in hits:
    print(f"{rel}:{line}: {sev}: {reason} ({rid})")

if hits:
    print(f"\n{len(hits)} new SwiftLint violation(s) on changed lines.", file=sys.stderr)
    sys.exit(1)
print("No new SwiftLint violations on changed lines.", file=sys.stderr)
PY
