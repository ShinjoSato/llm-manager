#!/usr/bin/env bash
# claude-deck を最新にして組み立て、/Applications の claude-deck.app と入れ替えて起動し直す。
#
# 使い方: mac/scripts/install.sh [--dest <dir>] [--no-pull] [--no-launch] [--adhoc] [--build-system auto|default|native]
#   --dest          入れる先（既定: /Applications）
#   --no-pull       develop を最新にせず、今の作業ツリーのまま組み立てる
#   --no-launch     入れ替えた後に起動しない
#   --adhoc / --build-system は bundle.sh にそのまま渡す
# 動いている claude-deck（同じバンドル ID）は ⌘Q と同じ普通の終了を頼む（稼働中・権限待ちがあれば確認が出る）。
# 取りやめられた・終わらなかった時は入れ替えない。初回は「claude-deck を操作する」許可を macOS が尋ねることがある。
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$MAC_DIR/.." && pwd)"
APP_NAME="claude-deck"
DEST="/Applications"
PULL=1
LAUNCH=1
BUNDLE_ARGS=()
# 終了の確認に答えるまで待つ時間（秒）。
QUIT_TIMEOUT=180

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?}"; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --adhoc) BUNDLE_ARGS+=("--adhoc"); shift ;;
    --build-system) BUNDLE_ARGS+=("--build-system" "${2:?}"); shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 2 ;;
  esac
done

if [[ $PULL -eq 1 ]]; then
  branch="$(git -C "$REPO_DIR" branch --show-current)"
  if [[ "$branch" != "develop" ]]; then
    echo "develop ではなく '${branch:-（detached）}' にいます。develop に切り替えるか、今のまま組み立てるなら --no-pull を付けてください。" >&2; exit 1
  fi
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    echo "作業ツリーに未コミットの変更があります。片付けるか、今のまま組み立てるなら --no-pull を付けてください。" >&2; exit 1
  fi
  echo "==> develop を最新にします"
  git -C "$REPO_DIR" pull --ff-only
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-deck-install.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
"$MAC_DIR/scripts/bundle.sh" --out "$BUILD_DIR" ${BUNDLE_ARGS[@]+"${BUNDLE_ARGS[@]}"}
NEW_APP="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist")"

TARGET="$DEST/$APP_NAME.app"
# 同じ名前の別のアプリを消さないよう、入っているものがこのアプリの時だけ入れ替える。
if [[ -e "$TARGET" ]]; then
  old_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$old_id" != "$BUNDLE_ID" ]]; then
    echo "$TARGET はバンドル ID が '${old_id:-（読めない）}' で、このアプリ（${BUNDLE_ID}）ではないため入れ替えません。" >&2; exit 1
  fi
fi

is_running() {
  [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == "true" ]]
}

if is_running; then
  echo "==> 動いている claude-deck に終了を頼みます（稼働中・権限待ちがあれば確認が出ます）"
  # 確認に答えるまで quit の返事が来ないので、既定の 2 分で切れないよう待ち時間を延ばす。
  if ! reply="$(osascript -e "with timeout of $QUIT_TIMEOUT seconds" -e "tell application id \"$BUNDLE_ID\" to quit" -e "end timeout" 2>&1)" && is_running; then
    echo "claude-deck が終了しませんでした（確認で取りやめたか、終了を頼む許可が無い: ${reply}）。" >&2
    echo "許可は「システム設定 → プライバシーとセキュリティ → オートメーション」で出せます。⌘Q で終了してから実行し直しても構いません。入れ替えていません。" >&2; exit 1
  fi
  waited=0
  while is_running; do
    if [[ $waited -ge $QUIT_TIMEOUT ]]; then
      echo "claude-deck が終了しませんでした（確認で取りやめた・作業の終わりを待っている等）。入れ替えていません。" >&2; exit 1
    fi
    sleep 1; waited=$((waited + 1))
  done
fi

echo "==> $TARGET に入れます"
mkdir -p "$DEST"
STAGED="$DEST/.$APP_NAME.app.installing"
rm -rf "$STAGED"
ditto "$NEW_APP" "$STAGED"
rm -rf "$TARGET"
mv "$STAGED" "$TARGET"

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> 起動します"
  open "$TARGET"
fi
echo "完了: ${TARGET}（バンドル ID: ${BUNDLE_ID}）"
