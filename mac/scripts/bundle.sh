#!/usr/bin/env bash
# claude-deck.app を組み立てて署名する（Developer ID 署名・公証はしない）。
#   このアプリ・この Mac・手元の証明書に合うプロビジョニングプロファイルがあれば Apple Development で署名し、
#   iCloud（CloudKit）のエンタイトルメントを付ける。無ければ従来どおり ad-hoc 署名（iCloud 経由の通知は無効。アプリが画面で理由を出す）。
#
# 使い方: mac/scripts/bundle.sh [--build-system auto|default|native] [--debug] [--out <dir>] [--profile <path>] [--adhoc]
#   --build-system  auto（既定）: 通常ビルドを試し、失敗したら native に切り替える
#                   Metal Toolchain が無い環境では通常ビルドが SwiftTerm のシェーダーで失敗するため
#   --debug         debug 構成でビルドする（既定は release）
#   --out           出力先ディレクトリ（既定: mac/dist）
#   --profile       使うプロファイル（合わなければ止まる。既定: 環境変数 CLAUDE_DECK_PROFILE → mac/Resources/claude-deck.provisionprofile →
#                   Xcode のプロファイル置き場から、App ID・iCloud コンテナ・この Mac・手元の証明書が合う macOS 用のもの）
#   --adhoc         プロファイルがあっても ad-hoc で署名する
#   署名の証明書はプロファイルに入っているものとキーチェーンの「Apple Development:」で一致するもの
#   （環境変数 CLAUDE_DECK_SIGN_IDENTITY でハッシュか名前の一部に絞れる）
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
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-deck-bundle.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# 署名に使える「Apple Development:」の証明書の SHA-1（大文字）。CLAUDE_DECK_SIGN_IDENTITY があれば、ハッシュか名前の一部で絞る。
SIGNING_HASHES="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -v want="${CLAUDE_DECK_SIGN_IDENTITY:-}" '/"Apple Development: / {
      if (want == "" || toupper($2) == toupper(want) || index($0, want) > 0) print toupper($2) }' || true)"
# 開発用のプロファイルは載っている端末でしか起動できないので、この Mac の Provisioning UDID と照合する（要る時に一度だけ引く）。
THIS_MAC_UDID=""

REJECT=""
IDENTITY=""
# このアプリ用（macOS・App ID・iCloud コンテナ・期限内・この Mac 入り・手元の証明書入り）なら、IDENTITY に署名の証明書を入れる。
profile_check() {
  local file="$1" plist="$TMP_DIR/profile.plist" value count i hash found
  IDENTITY=""
  if ! security cms -D -i "$file" > "$plist" 2>/dev/null; then REJECT="プロファイルを読めません"; return 1; fi
  value="$(plutil -extract Platform.0 raw -o - "$plist" 2>/dev/null || true)"
  if [[ "$value" != "OSX" ]]; then REJECT="macOS 用ではありません"; return 1; fi
  value="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$plist" 2>/dev/null || true)"
  if [[ "$value" != "$TEAM_ID.$BUNDLE_ID" ]]; then REJECT="App ID が ${TEAM_ID}.${BUNDLE_ID} ではありません"; return 1; fi
  value="$(plutil -extract 'Entitlements.com\.apple\.developer\.icloud-container-identifiers' json -o - "$plist" 2>/dev/null || true)"
  if [[ "$value" != *"\"$ICLOUD_CONTAINER\""* ]]; then REJECT="iCloud コンテナ ${ICLOUD_CONTAINER} が入っていません"; return 1; fi
  value="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || true)"
  if [[ "$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null || echo 0)" -le "$(date +%s)" ]]; then
    REJECT="期限が切れています"; return 1
  fi

  if [[ "$(plutil -extract ProvisionsAllDevices raw -o - "$plist" 2>/dev/null || true)" != "true" ]]; then
    if [[ -z "$THIS_MAC_UDID" ]]; then
      THIS_MAC_UDID="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ { print toupper($2); exit }' || true)"
    fi
    count="$(plutil -extract ProvisionedDevices raw -o - "$plist" 2>/dev/null || echo 0)"
    found=0
    if [[ -n "$THIS_MAC_UDID" ]]; then
      for ((i = 0; i < count; i++)); do
        value="$(plutil -extract "ProvisionedDevices.$i" raw -o - "$plist" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
        if [[ "$value" == "$THIS_MAC_UDID" ]]; then found=1; break; fi
      done
    fi
    if [[ "$found" != 1 ]]; then REJECT="この Mac（Provisioning UDID）が端末一覧に入っていません"; return 1; fi
  fi

  count="$(plutil -extract DeveloperCertificates raw -o - "$plist" 2>/dev/null || echo 0)"
  for ((i = 0; i < count; i++)); do
    hash="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$plist" 2>/dev/null | base64 -D 2>/dev/null \
      | openssl dgst -sha1 -r 2>/dev/null | awk '{ print toupper($1) }' || true)"
    if [[ -n "$hash" ]] && grep -qx "$hash" <<<"$SIGNING_HASHES"; then IDENTITY="$hash"; return 0; fi
  done
  REJECT="プロファイルの証明書に一致する「Apple Development:」の署名 ID がキーチェーンにありません"
  return 1
}

FOUND_PROFILE=""
select_profile() {
  if [[ -n "$PROFILE" ]]; then
    if profile_check "$PROFILE"; then FOUND_PROFILE="$PROFILE"; return 0; fi
    echo "==> 指定のプロファイルは使えません（${REJECT}）: ${PROFILE}" >&2
    exit 1
  fi
  local candidates=() files=() file dir
  if [[ -f "$MAC_DIR/Resources/claude-deck.provisionprofile" ]]; then
    candidates+=("$MAC_DIR/Resources/claude-deck.provisionprofile")
  fi
  shopt -s nullglob
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    files+=("$dir"/*.provisionprofile "$dir"/*.mobileprovision)
  done
  shopt -u nullglob
  # 新しいものから見る（置き場が空の時に ls を引数なしで走らせない）。
  if [[ ${#files[@]} -gt 0 ]]; then
    while IFS= read -r file; do candidates+=("$file"); done < <(ls -t "${files[@]}")
  fi
  for file in ${candidates[@]+"${candidates[@]}"}; do
    if profile_check "$file"; then FOUND_PROFILE="$file"; return 0; fi
  done
  return 1
}

SIGNED_WITH="ad-hoc"
if [[ "$FORCE_ADHOC" == 0 ]] && select_profile; then
  echo "==> Apple Development（${IDENTITY}）で署名します（プロファイル: ${FOUND_PROFILE}）"
  cp "$FOUND_PROFILE" "$APP/Contents/embedded.provisionprofile"
  # 同梱のチャネルは iCloud を使わないので、エンタイトルメント無しで先に署名する（--deep で同じ権限を配らない）。
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/$CHANNEL_NAME"
  codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
  SIGNED_WITH="Apple Development（iCloud 有効）"
else
  if [[ "$FORCE_ADHOC" == 0 ]]; then
    echo "==> このアプリ・この Mac・手元の証明書に合うプロビジョニングプロファイルが無いため ad-hoc で署名します（iCloud 経由の通知は無効）" >&2
  fi
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict --verbose "$APP"

echo "==> 完了: ${APP}（署名: ${SIGNED_WITH}）"
echo "    起動: open \"$APP\""
