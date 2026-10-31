#!/bin/sh
# claude-deck の perf.log（計測を有効にした時だけ書かれる）を集計する。依存は macOS 標準の awk だけ。
# 区間ごとのメインの合計時間の多い順・回数/秒・メインの詰まりの分布・文脈の平均を出す。
set -eu

usage() {
  cat <<'EOF'
使い方: perf-summary.sh [-t 件数] [perf.log]
  perf.log を省くと ~/Library/Logs/claude-deck/perf.log を読む。
  -t 件数   各表に出す行数（既定 20）
EOF
}

top=20
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -t) [ $# -ge 2 ] || { usage >&2; exit 2; }; top=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done
case $top in '' | *[!0-9]*) echo "-t には数を渡してください" >&2; exit 2 ;; esac

log=${1:-"$HOME/Library/Logs/claude-deck/perf.log"}
[ -r "$log" ] || { echo "読めません: $log" >&2; exit 1; }

LC_ALL=C awk -v top="$top" '
function field(name,   i, eq) {
  for (i = 3; i <= NF; i++) {
    eq = index($i, "=")
    if (eq > 0 && substr($i, 1, eq - 1) == name) return substr($i, eq + 1)
  }
  return ""
}
# score の大きい順に top 件の添字を order に入れ、件数を返す（標準の awk には並べ替えが無い）。
function rank(count, score, order,   i, j, best, used, picked) {
  picked = 0
  for (i = 1; i <= count && picked < top; i++) {
    best = 0
    for (j = 1; j <= count; j++) if (!(j in used) && (best == 0 || score[j] > score[best])) best = j
    if (best == 0) break
    used[best] = 1
    order[++picked] = best
  }
  return picked
}
$2 == "ctx" {
  windows++
  seconds += field("sec")
  if (first == "") first = $1
  last = $1
  for (i = 3; i <= NF; i++) {
    eq = index($i, "=")
    if (eq == 0) continue
    key = substr($i, 1, eq - 1)
    if (key == "sec") continue
    val = substr($i, eq + 1) + 0
    if (!(key in ctxSeen)) ctxOrder[++ctxCount] = key
    ctxSum[key] += val
    ctxSeen[key]++
    if (val > ctxMax[key]) ctxMax[key] = val
  }
}
$2 == "stall" {
  samples = field("samples") + 0
  stallSamples += samples
  stallOver += field("over250")
  if (samples > 0) {
    stallWindows++
    p95 = field("p95_ms") + 0
    p50Sum += field("p50_ms")
    p95Sum += p95
    if (field("max_ms") + 0 > stallMax) stallMax = field("max_ms") + 0
    if (p95 < 16) bucket1++
    else if (p95 < 50) bucket2++
    else if (p95 < 100) bucket3++
    else if (p95 < 250) bucket4++
    else bucket5++
  }
}
$2 == "span" || $2 == "count" {
  key = $2 " " field("thread") " " field("name")
  if (!(key in id)) { id[key] = ++rows; rowKind[rows] = $2; rowThread[rows] = field("thread"); rowName[rows] = field("name") }
  r = id[key]
  rowN[r] += field("n")
  rowTotal[r] += field("total_ms")
  rowValue[r] += field("value")
  if (field("max_ms") + 0 > rowMax[r]) rowMax[r] = field("max_ms") + 0
}
function spans(thread, title,   i, count, score, order, picked, k, r, sum) {
  count = 0
  sum = 0
  for (i = 1; i <= rows; i++) if (rowKind[i] == "span" && rowThread[i] == thread) { map[++count] = i; score[count] = rowTotal[i]; sum += rowTotal[i] }
  printf "\n== %s（合計時間の多い順・期間のうち %.2f%%）\n", title, (seconds > 0 ? sum / (seconds * 10) : 0)
  if (count == 0) { print "  （無し）"; return }
  printf "  %10s %7s %9s %9s %9s %12s  %s\n", "total_ms", "share%", "n", "n/s", "avg_ms", "max_ms", "name(value)"
  picked = rank(count, score, order)
  for (k = 1; k <= picked; k++) {
    r = map[order[k]]
    printf "  %10.1f %7.2f %9d %9.2f %9.3f %12.2f  %s", rowTotal[r], (seconds > 0 ? rowTotal[r] / (seconds * 10) : 0), rowN[r],
           rowN[r] / seconds, rowTotal[r] / (rowN[r] > 0 ? rowN[r] : 1), rowMax[r], rowName[r]
    if (rowValue[r] != 0) printf "（%d）", rowValue[r]
    printf "\n"
  }
}
END {
  if (windows == 0) { print "ctx の行がありません（計測を有効にして 10 秒以上動かしてください）"; exit 1 }
  if (seconds <= 0) seconds = windows * 10
  printf "期間: %s 〜 %s（%d 回・%.0f 秒）\n", first, last, windows, seconds

  print "\n== 文脈（10 秒ごとの値の平均 / 最大）"
  for (i = 1; i <= ctxCount; i++) {
    k = ctxOrder[i]
    printf "  %-10s 平均 %8.1f  最大 %6d\n", k, ctxSum[k] / ctxSeen[k], ctxMax[k]
  }

  print "\n== メインの詰まり（100ms ごとの印の遅れ）"
  printf "  印 %d 件・250ms 以上 %d 回・最大 %.1fms\n", stallSamples, stallOver, stallMax
  if (stallWindows > 0) {
    printf "  10 秒ごとの p50 の平均 %.2fms・p95 の平均 %.2fms\n", p50Sum / stallWindows, p95Sum / stallWindows
    printf "  p95 の分布（回）: <16ms %d / 16-50ms %d / 50-100ms %d / 100-250ms %d / 250ms 以上 %d\n",
           bucket1, bucket2, bucket3, bucket4, bucket5
  }

  spans("main", "メインの区間")
  spans("bg", "メイン以外の区間")

  count = 0
  for (i = 1; i <= rows; i++) if (rowKind[i] == "count") { cmap[++count] = i; cscore[count] = rowN[i] }
  print "\n== 回数（多い順）"
  if (count == 0) { print "  （無し）"; exit 0 }
  printf "  %9s %9s %-6s %s\n", "n", "n/s", "thread", "name(value)"
  picked = rank(count, cscore, corder)
  for (k = 1; k <= picked; k++) {
    r = cmap[corder[k]]
    printf "  %9d %9.2f %-6s %s", rowN[r], rowN[r] / seconds, rowThread[r], rowName[r]
    if (rowValue[r] != 0) printf "（%d）", rowValue[r]
    printf "\n"
  }
}
' "$log"
