# secrets/

秘密情報の置き場。**このディレクトリの中身は git に追跡されない**（`.gitignore` で
`secrets/*` を除外。例外は本 README と `*.example.json` テンプレのみ）。

## 置くもの

| ファイル | 内容 |
|---|---|
| `AuthKey_XXXXXXXXXX.p8` | App Store Connect API キー（秘密鍵）。ダウンロードは一度きり |
| `appstore-credentials.json` | Key ID・(Issuer ID)・鍵パス。`appstore-credentials.example.json` をコピーして作る |

## 手順

1. ダウンロードした `.p8` をこのフォルダに置く（`chmod 600` 推奨）
2. `cp appstore-credentials.example.json appstore-credentials.json` して中身を記入
   - `keyPath` はプロジェクトルートからの相対パスでも可（例 `secrets/AuthKey_XXXX.p8`）
   - 個人キー(Individual Key)なら `issuerId` は空のまま
3. `./scripts/appstore.py` で疎通確認

詳細は CLAUDE.md「App Store 審査状況」を参照。
