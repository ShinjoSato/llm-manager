# secrets/

秘密情報の置き場。**このディレクトリの中身は git に追跡されない**（`.gitignore` で
`secrets/*` を除外。例外は本 README のみ）。

## 置くもの

| ファイル | 内容 |
|---|---|
| `monitor-token` | monitor を同じ Wi-Fi の別端末から見る時（`MONITOR_LAN=1 npm start`）のアクセストークン。無ければ monitor が起動時に生成する |

トークンを持つ端末だけが LAN から monitor を開ける（`?t=<token>` で一度開くと cookie が付く）。
ループバック（手元）からの接続はトークン不要。漏れた時はこのファイルを消して monitor を起動し直せば作り直される。
詳細は `monitor/README.md` を参照。
