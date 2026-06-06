#!/usr/bin/env bash
# ai-manager: 登録済みプロジェクトの状況を一覧表示する
#
# 使い方:
#   ./scripts/status.sh              全 active プロジェクトの状況
#   ./scripts/status.sh --all        paused / archived も含めて表示
#   ./scripts/status.sh <name>       指定したプロジェクトだけ詳しく表示
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/projects/registry.tsv"

show_all=false
filter=""
case "${1:-}" in
  --all) show_all=true ;;
  "")    ;;
  *)     filter="$1" ;;
esac

if [[ ! -f "$REGISTRY" ]]; then
  echo "登録簿が見つかりません: $REGISTRY" >&2
  exit 1
fi

# 登録簿を読む（コメント・空行を除外）
entries=0
while IFS=$'\t' read -r name path status note; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue

  # フィルタ適用
  if [[ -n "$filter" && "$name" != "$filter" ]]; then continue; fi
  if [[ -z "$filter" && "$show_all" == false && "${status:-}" != "active" ]]; then continue; fi

  entries=$((entries+1))
  echo "════════════════════════════════════════════════════════"
  echo "📁 $name  [${status:-?}]"
  [[ -n "${note:-}" ]] && echo "   メモ: $note"
  echo "   path: $path"

  if [[ ! -d "$path" ]]; then
    echo "   ⚠️  ディレクトリが存在しません"
    continue
  fi

  if [[ -d "$path/.git" ]]; then
    branch=$(git -C "$path" branch --show-current 2>/dev/null || echo "?")
    last=$(git -C "$path" log -1 --format="%cd (%h) %s" --date=short 2>/dev/null || echo "コミットなし")
    dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "-")
    echo "   ブランチ: $branch | 未コミット変更: ${dirty}件 | 未push: ${ahead}件"
    echo "   最終コミット: $last"
  else
    echo "   (git管理されていません)"
  fi
done < "$REGISTRY"

echo "════════════════════════════════════════════════════════"
if [[ "$entries" -eq 0 ]]; then
  echo "表示対象がありません。projects/registry.tsv に管理対象を登録してください。"
else
  echo "$entries 件表示しました。"
fi
