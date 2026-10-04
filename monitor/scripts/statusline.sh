#!/bin/sh
# 旧 statusLine のパスを指す settings.json でも使用量を記録し続けるため、mac 側のスクリプトに渡すだけ。
# settings.json の statusLine を mac/scripts/statusline.sh に差し替えたら、このファイルは消してよい。
exec "$(dirname -- "$0")/../../mac/scripts/statusline.sh" "$@"
