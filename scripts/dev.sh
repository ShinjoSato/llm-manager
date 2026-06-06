#!/usr/bin/env bash
# ai-manager: API サーバーと Web 開発サーバーを同時に起動する。
#   ./scripts/dev.sh
#
#   - API : http://localhost:8765  (server/ … HTTP/JSON + MCP と同じデータ中核)
#   - Web : http://localhost:5173  (web/ … Vite。/api は 8765 にプロキシ)
#
# Ctrl-C で両方まとめて停止する。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 依存が無ければ自動インストール
[ -d "$ROOT/server/node_modules" ] || (echo "📦 server の依存をインストール..." && cd "$ROOT/server" && npm install)
[ -d "$ROOT/web/node_modules" ]    || (echo "📦 web の依存をインストール..."    && cd "$ROOT/web"    && npm install)

# 終了時にプロセスグループごと停止（npm が起こす node 子プロセスも巻き取る）
cleanup() { trap - INT TERM EXIT; echo; echo "🛑 停止中..."; kill 0; }
trap cleanup INT TERM EXIT

echo "▶ API を起動 → http://localhost:8765"
(cd "$ROOT/server" && npm run http) &

echo "▶ Web を起動 → http://localhost:5173"
(cd "$ROOT/web" && npm run dev) &

echo "──────────────────────────────────────────"
echo "  ブラウザで http://localhost:5173 を開く"
echo "  停止するには Ctrl-C"
echo "──────────────────────────────────────────"
wait
