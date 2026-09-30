#!/bin/sh
# Claude Code の statusLine から呼ばれる。標準入力の JSON を表示し、使用量を data/claude-usage.json に残す。
# 高頻度で呼ばれるので、重い処理・外部通信は入れない。
input=$(cat)

five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

# 整数以外を算術展開に渡すとエラーで表示が壊れるので、ここで捨てる。
case $five_reset in '' | *[!0-9]*) five_reset="" ;; esac

parts=""

if [ -n "$five_pct" ]; then
  five_pct_int=$(LC_ALL=C printf '%.0f' "$five_pct")
  if [ -n "$five_reset" ]; then
    now=$(date +%s)
    diff=$((five_reset - now))
    if [ "$diff" -le 0 ]; then
      reset_str="まもなく"
    else
      h=$((diff / 3600))
      m=$(( (diff % 3600) / 60 ))
      if [ "$h" -gt 0 ]; then
        reset_str="${h}時間${m}分後"
      else
        reset_str="${m}分後"
      fi
    fi
    parts="セッション: ${five_pct_int}% (リセット: ${reset_str})"
  else
    parts="セッション: ${five_pct_int}%"
  fi
fi

if [ -n "$week_pct" ]; then
  week_pct_int=$(LC_ALL=C printf '%.0f' "$week_pct")
  week_part="週間: ${week_pct_int}%"
  if [ -n "$parts" ]; then
    parts="${parts} | ${week_part}"
  else
    parts="$week_part"
  fi
fi

# 書き込みより先に出す。記録に失敗しても表示内容は変わらない。
if [ -n "$parts" ]; then
  printf "%s" "$parts"
fi

# 値が 1 つも取れない入力では、既にある記録を上書きしない。
[ -n "$five_pct" ] || [ -n "$week_pct" ] || exit 0

# 出力先は配置場所から引く（monitor/scripts の 2 つ上が ai-manager のルート）。
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
[ -n "$script_dir" ] || exit 0
out_dir="${script_dir}/../../data"
out="${out_dir}/claude-usage.json"

usage=$(echo "$input" | jq -c --argjson now "$(date +%s)000" '
  def win: if . == null or .used_percentage == null then null
    else { usedPercentage: .used_percentage, resetsAt: (if (.resets_at | type) == "number" then .resets_at * 1000 else null end) } end;
  { fetchedAt: $now, fiveHour: (.rate_limits.five_hour | win), sevenDay: (.rate_limits.seven_day | win) }
' 2>/dev/null) || exit 0
[ -n "$usage" ] || exit 0

# 同じディレクトリ内の mv は原子的。読み手が半端な JSON を掴まない。
mkdir -p "$out_dir" 2>/dev/null || exit 0
tmp="${out}.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
if printf '%s\n' "$usage" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi
exit 0
