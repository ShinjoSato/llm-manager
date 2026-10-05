#!/usr/bin/env bash
# claude-deck.app を組み立てて署名する（Developer ID 署名・公証はしない）。
#   プロビジョニングプロファイルがあれば Apple Development で署名し、iCloud（CloudKit）のエンタイトルメントを付ける。
#   無ければ従来どおり ad-hoc 署名（iCloud 経由の通知は無効。アプリが画面で理由を出す）。
#
# 使い方: mac/scripts/bundle.sh [--build-system auto|default|native] [--debug] [--out <dir>] [--profile <path>] [--adhoc]
#   --build-system  auto（既定）: 通常ビルドを試し、失敗したら native に切り替える
#                   Metal Toolchain が無い環境では通常ビルドが SwiftTerm のシェーダーで失敗するため
#   --debug         debug 構成でビルドする（既定は release）
#   --out           出力先ディレクトリ（既定: mac/dist）
#   --profile       使うプロファイル（既定: 環境変数 CLAUDE_DECK_PROFILE → mac/Resources/claude-deck.provisionprofile →
#                   ~/Library/Developer/Xcode/UserData/Provisioning Profiles/ から App ID が合う macOS 用のもの）
#   --adhoc         プロファイルがあっても ad-hoc で署名する
#   署名の ID は環境変数 CLAUDE_DECK_SIGN_IDENTITY（既定: キーチェーンの最初の「Apple Development:」）
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="claude-deck"
# Claude Code が .mcp.json から起動するチャネル。.app の中の絶対パスで登録できるよう同梱する。
CHANNEL_NAME="claude-deck-channel"
BUILD_SYSTEM="auto"
CONFIG="release"
OUT_DIR="$MAC_DIR/dist"
TEAM_ID="ZCYQMLA9HP"
BUNDLE_ID="com.shinjosato.claude-deck"
ICLOUD_CONTAINER="iCloud.com.shinjosato.claude-deck"
ENTITLEMENTS="$MAC_DIR/Resources/claude-deck.entitlements"
PROFILE="${CLAUDE_DECK_PROFILE:-}"
FORCE_ADHOC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-system) BUILD_SYSTEM="${2:?}"; shift 2 ;;
    --debug) CONFIG="debug"; shift ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 2 ;;
  esac
done

cd "$MAC_DIR"

build() {
  local extra=("$@")
  swift build -c "$CONFIG" --product "$APP_NAME" ${extra[@]+"${extra[@]}"} \
    && swift build -c "$CONFIG" --product "$CHANNEL_NAME" ${extra[@]+"${extra[@]}"} \
    && BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path ${extra[@]+"${extra[@]}"})"
}

case "$BUILD_SYSTEM" in
  default) build ;;
  native) build --build-system native ;;
  auto)
    if ! build; then
      echo "==> 通常ビルドに失敗。--build-system native で再試行します" >&2
      build --build-system native
    fi
    ;;
  *) echo "--build-system は auto|default|native のいずれか" >&2; exit 2 ;;
esac

APP="$OUT_DIR/$APP_NAME.app"
echo "==> $APP を組み立てます（bin: ${BIN_DIR}）"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/$CHANNEL_NAME" "$APP/Contents/MacOS/$CHANNEL_NAME"
cp "$MAC_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 依存パッケージのリソースバンドル（SwiftTerm_SwiftTerm.bundle 等）を同梱する。
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

# アイコンは任意。mac/Resources/AppIcon.icns があれば載せる。
if [[ -f "$MAC_DIR/Resources/AppIcon.icns" ]]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

plutil -lint "$APP/Contents/Info.plist"

# SPM のリソースは読み取り専用で出力され、拡張属性が残ると codesign が拒否するため整えてから署名する。
chmod -R u+w "$APP"
xattr -cr "$APP"
# プロファイルを読む（cms の署名を外した plist）。
profile_value() {
  security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null
}

# このアプリ用（macOS・App ID 一致・iCloud コンテナ入り・期限内）のプロファイルか。
profile_matches() {
  local file="$1" platform app_id containers expires
  platform="$(profile_value "$file" Platform.0)" || return 1
  app_id="$(profile_value "$file" 'Entitlements.com\.apple\.application-identifier')" || return 1
  [[ "$platform" == "OSX" && "$app_id" == "$TEAM_ID.$BUNDLE_ID" ]] || return 1
  containers="$(security cms -D -i "$file" 2>/dev/null | plutil -extract 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' json -o - - 2>/dev/null)" || return 1
  [[ "$containers" == *"\"$ICLOUD_CONTAINER\""* ]] || return 1
  expires="$(profile_value "$file" ExpirationDate)" || return 1
  [[ "$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ]]
}

find_profile() {
  if [[ -n "$PROFILE" ]]; then
    profile_matches "$PROFILE" && { echo "$PROFILE"; return 0; }
    echo "==> 指定のプロファイルはこのアプリ用ではありません（macOS・${TEAM_ID}.${BUNDLE_ID}・${ICLOUD_CONTAINER}・期限内か）: ${PROFILE}" >&2
    return 1
  fi
  local candidate
  if [[ -f "$MAC_DIR/Resources/claude-deck.provisionprofile" ]]; then
    candidate="$MAC_DIR/Resources/claude-deck.provisionprofile"
    profile_matches "$candidate" && { echo "$candidate"; return 0; }
  fi
  shopt -s nullglob
  # 新しいものから見る。
  local files=()
  while IFS= read -r candidate; do files+=("$candidate"); done < <(ls -t "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile 2>/dev/null)
  shopt -u nullglob
  for candidate in ${files[@]+"${files[@]}"}; do
    profile_matches "$candidate" && { echo "$candidate"; return 0; }
  done
  return 1
}

sign_identity() {
  if [[ -n "${CLAUDE_DECK_SIGN_IDENTITY:-}" ]]; then echo "$CLAUDE_DECK_SIGN_IDENTITY"; return 0; fi
  # 名前ではなくハッシュで渡す（同名の証明書が複数あっても曖昧にならない）。
  security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' | grep .
}

SIGNED_WITH="ad-hoc"
if [[ "$FORCE_ADHOC" == 0 ]] && FOUND_PROFILE="$(find_profile)" && IDENTITY="$(sign_identity)"; then
  echo "==> Apple Development で署名します（プロファイル: ${FOUND_PROFILE}）"
  cp "$FOUND_PROFILE" "$APP/Contents/embedded.provisionprofile"
  # 同梱のチャネルは iCloud を使わないので、エンタイトルメント無しで先に署名する（--deep で同じ権限を配らない）。
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/$CHANNEL_NAME"
  codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
  SIGNED_WITH="Apple Development（iCloud 有効）"
else
  if [[ "$FORCE_ADHOC" == 0 ]]; then
    echo "==> このアプリ用のプロビジョニングプロファイル（または Apple Development の証明書）が無いため ad-hoc で署名します（iCloud 経由の通知は無効）" >&2
  fi
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict --verbose "$APP"

echo "==> 完了: ${APP}（署名: ${SIGNED_WITH}）"
echo "    起動: open \"$APP\""
