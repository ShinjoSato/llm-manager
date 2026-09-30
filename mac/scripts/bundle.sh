#!/usr/bin/env bash
# claude-deck.app を組み立てて ad-hoc 署名する（Developer ID 署名・公証はしない）。
#
# 使い方: mac/scripts/bundle.sh [--build-system auto|default|native] [--debug] [--out <dir>]
#   --build-system  auto（既定）: 通常ビルドを試し、失敗したら native に切り替える
#                   Metal Toolchain が無い環境では通常ビルドが SwiftTerm のシェーダーで失敗するため
#   --debug         debug 構成でビルドする（既定は release）
#   --out           出力先ディレクトリ（既定: mac/dist）
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="claude-deck"
BUILD_SYSTEM="auto"
CONFIG="release"
OUT_DIR="$MAC_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-system) BUILD_SYSTEM="${2:?}"; shift 2 ;;
    --debug) CONFIG="debug"; shift ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 2 ;;
  esac
done

cd "$MAC_DIR"

build() {
  local extra=("$@")
  swift build -c "$CONFIG" --product "$APP_NAME" ${extra[@]+"${extra[@]}"} \
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
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> 完了: $APP"
echo "    起動: open \"$APP\""
