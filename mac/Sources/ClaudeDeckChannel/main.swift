import Foundation
import MonitorKit

// Claude Code が `.mcp.json` から起動するチャネル（stdio の MCP サーバー）。権限確認を claude-deck の画面へ中継する。

// Claude Code が先に終わって stdout が閉じても、書き込みで落ちずに stdin の終わりで抜ける。
signal(SIGPIPE, SIG_IGN)
await ChannelServer().run()
exit(0)
