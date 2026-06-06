#!/usr/bin/env bash
# ai-manager: 管理対象に紐づく GitHub Project（ボード）の状況を表示する
#
# 使い方:
#   ./scripts/board.sh             全ボードの「未完了（Todo/In Progress/Debug）」を表示
#   ./scripts/board.sh <name>      指定ボードのみ
#   ./scripts/board.sh --done      Done も含めて表示
#   ./scripts/board.sh <name> --done
#
# 前提: gh CLI が認証済みで 'project' スコープを持つこと。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP="$ROOT/projects/github-projects.tsv"

filter=""
include_done="false"
for a in "$@"; do
  case "$a" in
    --done) include_done="true" ;;
    *)      filter="$a" ;;
  esac
done

if [[ ! -f "$MAP" ]]; then
  echo "マッピングが見つかりません: $MAP" >&2; exit 1
fi
command -v gh >/dev/null || { echo "gh CLI が見つかりません" >&2; exit 1; }

shown=0
while IFS=$'\t' read -r name owner number repo url; do
  [[ -z "${name:-}" || "${name:0:1}" == "#" ]] && continue
  [[ -n "$filter" && "$name" != "$filter" ]] && continue
  shown=$((shown+1))

  echo "════════════════════════════════════════════════════════"
  echo "📋 $name  (Project #$number / $repo)"
  echo "   $url"

  gh project item-list "$number" --owner "$owner" --limit 1000 --format json 2>/dev/null \
  | INCLUDE_DONE="$include_done" python3 -c '
import sys, json, os
from collections import defaultdict
include_done = os.environ.get("INCLUDE_DONE") == "true"
data = json.load(sys.stdin)
items = data.get("items", [])
order = ["Todo", "In Progress", "Debug", "Done"]
groups = defaultdict(list)
for it in items:
    groups[it.get("status") or "(no status)"].append(it)
# サマリ
summary = " / ".join(f"{s}:{len(groups.get(s,[]))}" for s in order if groups.get(s))
extra = [k for k in groups if k not in order]
for k in extra: summary += f" / {k}:{len(groups[k])}"
print(f"   計 {len(items)}件  [{summary}]")
shown_keys = order if include_done else [s for s in order if s != "Done"]
for st in shown_keys + [k for k in extra]:
    arr = groups.get(st, [])
    if not arr: continue
    print(f"   ── {st} ({len(arr)}) ──")
    for it in arr:
        c = it.get("content", {}) or {}
        num = c.get("number")
        ref = f"#{num} " if num else ""
        title = it.get("title") or c.get("title") or "(無題)"
        asn = it.get("assignees")
        asn = f"  @{asn}" if asn else ""
        repo = c.get("repository", "")
        repo = "[" + repo.split("/")[-1] + "] " if repo else ""
        print(f"      {repo}{ref}{title}{asn}")
if not include_done:
    nd = len(groups.get("Done", []))
    if nd: print(f"   (Done {nd}件は省略。--done で表示)")
' || echo "   ⚠️ 取得に失敗しました（gh の認証/スコープを確認）"
done < "$MAP"

echo "════════════════════════════════════════════════════════"
[[ "$shown" -eq 0 ]] && echo "対象ボードがありません。" || echo "$shown 件のボードを表示しました。"
