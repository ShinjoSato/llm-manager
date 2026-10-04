# claude-deck（iPhone）

同じ Wi-Fi の Mac で動いている claude-deck（`mac/`）の「iPhone 連携」の口につなぎ、Claude Code のセッションを見て答える iPhone アプリ。
API の仕様は `mac/docs/remote-api.md`、通信と型は共有パッケージ `packages/DeckCore`。

- SwiftUI・iOS 17 以上・iPhone のみ・ダーク固定
- バンドル ID `com.shinjosato.claude-deck.ios` / チーム `ZCYQMLA9HP` / 署名は自動 / 版は `MARKETING_VERSION`（0.1.0）と `CURRENT_PROJECT_VERSION`（1）

## できること

| 画面 | 内容 |
|---|---|
| ペアリング | カメラで QR を読む・QR の内容（`claude-deck://pair?…`）を貼り付ける・他のアプリから `claude-deck://pair` で開かれる。**どの入口も、Mac の名前・接続先・証明書の指紋を見せる確認画面で「ペアリングする」を押すまで何も送らない**。期限切れ・版違いの QR は送る前に断る |
| ルーム一覧 | 要対応 / 稼働中 / 待機（Mac の並び順のまま）。ドット絵のアイコン・外部タグ・ブランチ・状態と直近の一行・時刻・未読（開いていない間に届いた応答の数）・要回答の印 |
| 会話 | ユーザーは右の青、Claude は左の暗色（Markdown の見出し・表・リスト・引用・コード）、画像のサムネイル（押すと全画面）、ツールは「ツール N件 ▸」、外部セッションへ送った伝言は点線の吹き出し |
| カード | 権限（Channels → 端末のプロンプトの順。許可 / 拒否）、選択肢（選択・複数選択・問いのタブ・キャンセル。Esc が終了になるメニューは確認してから `confirmExit`）、読めない選択肢（閉じるだけ）、Channels の無い外部セッションの案内 |
| 入力欄 | ホスト中のセッションはメッセージ、外部セッションは伝言。Mac が送れない理由（選択待ち等）を出している間は無効 |
| 接続 | Mac 名・再接続・ペアリングの解除（Mac から取り消し + 鍵を消す） |

操作の結果は `RemoteResultText`（DeckCore）で日本語にして会話の末尾に出す（`answered` / `gone` / `changed` / `busy` / `timeout` / `blocked_menu` …）。
`timeout` は「後から反映されることがある」旨を出し、自動では送り直さない。

## 接続と切れた時

- 前に出たら `/v1/events?transcripts=*` を 1 本張る（`state` で一覧、`transcript` で開いている会話の追記と未読）。
  会話を開いた時・張り直した時は、ストリームの後に全件を取り、id で重ねる（`TranscriptBuffer`）。会話を持つのは直近の 4 ルームだけ。
- 裏に回ったら閉じる（iOS は裏で接続を保てない）。前に出たら張り直す。
- 切れたら上部に理由と案内を出し、1 → 2 → 4 … 30 秒（揺らぎ付き）で張り直す。回数制限（429）は 1〜2 分待つ。Wi-Fi に戻ったら待たずに張り直す。
  案内: 同じ Wi-Fi か / Mac がスリープしていないか / Mac の「iPhone 連携」が有効か（別のネットワークでは止まる）/ ローカルネットワークの許可。
  失敗が続いて Mac が接続元を塞いでいる間は TLS の握手前に切られるので、「接続が切れました（数分で戻る）」として扱う。
- 届かない時は QR の予備の名前（`xxx.local`）でも試す。
- 証明書の指紋が違う・端末が取り消された時は張り直さず、「ペアリングし直す」を出す。

## 安全のための決めごと

- TLS は CA の検証をせず、サーバー証明書（DER）の SHA-256 がピンと一致した時だけ `.useCredential`（`RemotePinnedSessionDelegate`）。
- 接続先・指紋・端末トークンはキーチェーン（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。iCloud キーチェーン・他の端末へのバックアップに載らない）。
- Info.plist（`ios/Info.plist`。他は Xcode が生成）:
  - `NSAppTransportSecurity` は `NSAllowsLocalNetworking` だけ（LAN の IP / `.local` に自己署名の TLS で繋ぐため。他の通信は無い）
  - `NSCameraUsageDescription`（QR）・`NSLocalNetworkUsageDescription`（Mac とのやり取り）
  - `ITSAppUsesNonExemptEncryption = false`: 暗号は OS の TLS（URLSession）と、証明書の指紋の SHA-256（認証のためのハッシュ）だけで、
    独自の暗号は持たないため（輸出規制の申告が要らない範囲）
  - URL スキーム `claude-deck`（QR をカメラアプリで読んだ時にこのアプリで開く。確認画面を経る）
- 吹き出しのリンクは http / https だけ開く。

## 作り

```
ios/
  ClaudeDeck.xcodeproj/       手書きのプロジェクト（フォルダ同期のグループ・DeckCore はローカルの Swift Package・共有スキーム ClaudeDeck）
  Info.plist                  上の追加分だけ（GENERATE_INFOPLIST_FILE と合わせる。フォルダ同期の外に置いてリソース扱いさせない）
  ClaudeDeck/
    App/                      @main・RootView・画面確認用の見本データ（Debug のみ）
    Model/                    AppModel（接続・一覧・会話・操作）・PairingKeychain・RoomCards（カードの優先順・リンクの解析）
    Theme/DeckTheme.swift     mac のチャット画面と同じトークン
    Views/                    PixelAvatar・接続の帯と設定・Pairing/・Rooms/・Conversation/（MarkdownView は mac から移植）
    Assets.xcassets           アプリアイコン（scripts/make-app-icon.sh で DeckCore のドット絵から描く）・AccentColor
  ClaudeDeckTests/            リンクの解析と確認待ち・キーチェーン・カードの優先順・DeckCore の判定（iOS 上）・自己署名 TLS への接続（ATS の確認）
  scripts/make-app-icon.sh    アイコンを描き直す
```

ファイルは `ios/ClaudeDeck/` か `ios/ClaudeDeckTests/` に置けば、プロジェクトの編集なしに入る（`PBXFileSystemSynchronizedRootGroup`）。

## ビルド・テスト

```sh
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPhone 17' test
# 実機向け（署名なしで通るかだけ）
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
# 共有パッケージ
cd packages/DeckCore && swift test
```

画面だけ見たい時は Debug ビルドを起動引数 `-demo rooms` / `-demo conversation` で開く（通信しない見本のデータ）。

## TestFlight に出す

1. Xcode で `ios/ClaudeDeck.xcodeproj` を開き、Signing & Capabilities でチーム `ZCYQMLA9HP`・自動署名を確かめる。
2. App Store Connect にバンドル ID `com.shinjosato.claude-deck.ios` のアプリを作る（無ければ。名前は App Store 全体で一意）。
3. 送るたびに `CURRENT_PROJECT_VERSION` を上げる。Product → Archive → Distribute App → TestFlight & App Store。
4. 輸出規制の質問は Info.plist の `ITSAppUsesNonExemptEncryption = false` で省かれる。外部テスターに配る時は Beta App Review があり、
   審査用のメモに「同じ Wi-Fi の Mac アプリとペアリングして使う。Mac 無しではペアリング画面まで」と書く。
