#!/bin/zsh
# アプリアイコンを DeckCore のドット絵から描き直す（キャラの絵・配色を変えた時に実行する）。
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O -o "$work/make-icon" \
  "$root/packages/DeckCore/Sources/DeckCore/Pixel/PixelCharacter.swift" \
  "$root/packages/DeckCore/Sources/DeckCore/Models/MonitorModels.swift" \
  "$here/AppIcon/main.swift"
"$work/make-icon" "$root/ios/ClaudeDeck/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
