# claude-deck（iPhone・iPad）

同じ Wi-Fi の Mac で動いている claude-deck（`mac/`）の「iPhone 連携」の口につなぎ、Claude Code のセッションを見て答える iPhone・iPad アプリ。
API の仕様は `mac/docs/remote-api.md`、通信と型は共有パッケージ `packages/DeckCore`。

- SwiftUI・iOS 17 以上・iPhone と iPad の両対応（`TARGETED_DEVICE_FAMILY = 1,2`。iPad は全向き・Split View / Slide Over 可）・ダーク固定
- バンドル ID `$(DECK_BUNDLE_PREFIX).ios` / チーム `$(DEVELOPMENT_TEAM)`（どちらも `config/Local.xcconfig` に書く。下の「署名・識別子」）/ 署名は自動 / 版は `MARKETING_VERSION`（0.1.0）と `CURRENT_PROJECT_VERSION`（1）

## できること

| 画面 | 内容 |
|---|---|
| ペアリング | カメラで QR を読む・QR の内容（`claude-deck://pair?…`）を貼り付ける・他のアプリから `claude-deck://pair` で開かれる。**どの入口も、Mac の名前・接続先・証明書の指紋を見せる確認画面で「ペアリングする」を押すまで何も送らない**。期限切れ・版違いの QR、接続先が LAN の外（プライベート IPv4・169.254/16・`.local` の名前以外）のリンクは送る前に断る。カメラ以外（貼り付け・他のアプリから）の入口は確認画面で出どころの注意を出す |
| ルーム一覧 | 要対応 / 稼働中 / 待機（Mac の並び順のまま）。ドット絵のアイコン・外部タグ・ブランチ・状態と直近の一行・時刻・未読（開いていない間に届いた応答の数）・要回答の印 |
| 会話 | ユーザーは右の青、Claude は左の暗色（Markdown の見出し・表・リスト・引用・コード）、画像のサムネイル（押すと全画面）、ツールは「ツール N件 ▸」、外部セッションへ送った伝言は点線の吹き出し |
| カード | 権限（Channels → 端末のプロンプトの順。許可 / 拒否）、選択肢（選択・複数選択・問いのタブ・キャンセル。Esc が終了になるメニューの取り消しと、終了になる選択肢（trust 確認の「No, exit」。mac の `exits` の印、印を付けない古い mac には `confirm_required` が返ってから。返事の時に開いている会話だけ・60 秒まで）は確認してから `confirmExit`）、読めない選択肢（閉じるだけ）、Channels の無い外部セッションの案内 |
| 端末の画面 | カードで答えられない時の逃げ道（mac の「端末の画面」と同じ）。ホスト中で claude が動いているルームの見出しの端末のボタンと、端末の権限・選択肢・読めない選択肢のカードの「端末の画面」（カードの無効化の外に置くので送信中でも押せる）から開く。Mac の端末の今の表示を 0.7 秒ごとに取り直して等幅で出し（変わった時だけ描き直す・つながっていない間は取りに行かず 4 倍の間隔で待つ・重なった取り直しの古い応答とキーを送る前の取り直しの応答は捨てる。iPhone は小さめの文字で縦横にスクロール、iPad は大きめの文字で、iOS 18 からはページの大きさのシート）、← ↑ ↓ → Enter Esc Tab Space 1〜9 のボタンで 1 回ずつ送る（送っている間・表示が取れない間は押せない。押すとすぐ取り直す）。文字の自由入力は無い。Esc が claude の終了になるメニュー（`escapeExits`）では確認してから `confirmExit` で送る。Esc は端末に送るキーなので、下へのスワイプでは閉じず「閉じる」で閉じる。閉じたら取り直しをやめる（`AppModel.watchTerminal` / `stopWatchingTerminal`。開いているのは 1 つだけ・最後に開いたシートだけが止められる）。シートを重ねている間は下の会話を開いたままとして扱う（未読を数えない）。口の無い古い Mac には「Mac の claude-deck を更新してください」を出す |
| 入力欄 | ホスト中のセッションはメッセージ、外部セッションは伝言。Mac が送れない理由（選択待ち等）を出している間は無効。ホスト中のセッション（Mac の `send.acceptsImages` が true）には写真を添えられる（下の「画像を送る」）。ハードウェアキーボードでは ⏎ 送信・⇧⏎（⌥⏎）改行。本文は UITextView（`ComposerTextView`）で、⏎ を IME に渡す前（`pressesBegan`）に変換中かを見て、変換中なら確定に使う。ソフトウェアキーボードの改行キーは改行のまま |
| 接続 | Mac 名・再接続・ペアリングの解除（Mac から取り消し + 鍵を消す）・要対応の通知の入り切り |
| 通知 | Mac で要対応が続くと iCloud 経由でプッシュ（アプリを閉じていても・外出先でも）。開くと該当ルームへ（つながっていなければ案内を出し、つながって一覧が届いたら開く） |

### 画面の組み方（iPhone・iPad）

- 横幅が regular（iPad の全画面・広い Split View）: 左にルーム一覧・右に会話の 2 列（`NavigationSplitView`。縦向きでも 2 列で出し、一覧は左上のボタンで畳める）。
  未選択の時は右に案内を出す。選んだルームが一覧から消えたら選択を外して案内に戻す（`RoomSelection.kept`）。通知から開くルームも右に開く。
  接続の帯と一覧の上の案内（監視が止まっている・通知のルームを開けなかった）は一覧の側に出し、一覧を畳んでいる間だけ右の側に出す。
- 横幅が compact（iPhone・iPad の狭い Split View / Slide Over）: 一覧 → 会話の積み上げ（消えたルームの会話は「もう一覧にありません」を出したまま）。
- 開いている会話は 2 列と積み上げで共有するので、Split View の幅を変えても同じ会話のまま。画面が作り直される間の「開いた・閉じた」は画面ごとの印で受け、最後に開いた画面だけが閉じられる（未読・アプリ内の通知が狂わない）。
- 文言の端末名は `DeviceKind`（iPhone / iPad）で出し分ける。QR の読み取りは iPad の横向き・逆さでも映像を水平に保つ（`AVCaptureDevice.RotationCoordinator`）。
- 会話の本文と入力欄は最大 760pt、ペアリングの画面は最大 560pt に収めて中央に寄せる（`DeckTheme.readableWidth` / `formWidth`）。

操作の結果は `RemoteResultText`（DeckCore）で日本語にして会話の末尾に出す（`answered` / `gone` / `changed` / `busy` / `timeout` / `blocked_menu` …）。
`timeout` は「後から反映されることがある」旨を出し、自動では送り直さない。

## 画像を送る

- 入力欄の左の写真のボタン（`PhotosPicker`・複数選択可・残りの枚数まで。写真ライブラリの許可は要らない）で選ぶと、入力欄の上にサムネイルを並べ、× で外せる。本文が空でも画像だけで送れる。
- 上限は Mac と同じ `RemoteImageLimits`（1 通 4 枚・1 枚 3MB・合計 8MB）。送る前に `ComposerImagePreparer`（`Model/ComposerImages.swift`）で
  長辺 2048 ピクセルまで縮め、向きを反映し、位置情報などのメタデータを落として書き直す。PNG（スクリーンショット等）は 1 枚 2MB に収まれば PNG のまま、
  それ以外（HEIC を含む）と収まらない PNG は JPEG（品質を下げ、それでも入らなければさらに縮める）にする。整えられなかった写真は理由を出す。
- 送信中・失敗の扱いは文字の送信と同じ（送れたら本文と画像を空にし、送れなければ残して理由を出す）。伝言（外部セッション）と、画像を知らない古い Mac には付けない。

## 接続と切れた時

- 前に出たら `/v1/events?transcripts=*` を 1 本張る（`state` で一覧、`transcript` で開いている会話の追記と未読）。
  会話を開いた時・張り直した時は、ストリームの後に全件を取り、id で重ねる（`TranscriptBuffer`）。会話を持つのは直近の 4 ルームだけ。
- 裏に回ったら閉じる（iOS は裏で接続を保てない）。前に出たら張り直す。
- 切れたら上部に理由と案内を出し、1 → 2 → 4 … 30 秒（揺らぎ付き）で張り直す。回数制限（429）は 1〜2 分待つ。Wi-Fi に戻ったら待たずに張り直す。
  案内: 同じ Wi-Fi か / Mac がスリープしていないか / Mac の「iPhone 連携」が有効か（別のネットワークでは止まる）/ ローカルネットワークの許可。
  失敗が続いて Mac が接続元を塞いでいる間は TLS の握手前に切られるので、「切れたか、つながらなかった（数分で戻る）」として扱う。
- iOS はローカルネットワークの許可が無い時も Wi-Fi 上で -1009（`notConnectedToInternet`）を返すので、この時だけ接続先へ
  `NWConnection`（TCP・2 秒）を張り、経路の `unsatisfiedReason` で言い分ける（`ios/ClaudeDeck/Model/PathProbe.swift`、判定は DeckCore の
  `RemoteIssue.diagnose`）: `.localNetworkDenied` → 許可が無い（接続バナー・ペアリング画面に「設定を開く」。設定から戻ると張り直す）/
  経路なし・端末が Wi-Fi でない → Wi-Fi につながっていない / それ以外 → 両方を挙げる。
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
    Model/                    AppModel（接続・一覧・会話・操作・通知から開く・送る前の画像・端末の画面の取り直し）・ComposerImages（写真を送れる形に整える）・PairingKeychain・RoomCards（カードの優先順・リンクの解析）・RoomSelection（2 列の選択）
    Notify/                   要対応の通知（iCloud の購読・通知の受け口 DeckAppDelegate・設定の欄）
    ja.lproj/                 通知の見出し・本文のキー
    Theme/DeckTheme.swift     mac のチャット画面と同じトークン
    Views/                    PixelAvatar・接続の帯と設定・Pairing/・Rooms/・Conversation/（MarkdownView は mac から移植・TerminalScreenSheet は「端末の画面」）
    Assets.xcassets           アプリアイコン（scripts/make-app-icon.sh で DeckCore のドット絵から描く）・AccentColor
  ClaudeDeckTests/            リンクの解析と確認待ち・キーチェーン・カードの優先順・2 列の選択・入力欄の変換中の判定・DeckCore の判定（iOS 上）・自己署名 TLS への接続（ATS の確認）・写真の整え方と入力欄の画像・端末の画面の取り直しの開始 / 停止
  scripts/make-app-icon.sh    アイコンを描き直す
```

ファイルは `ios/ClaudeDeck/` か `ios/ClaudeDeckTests/` に置けば、プロジェクトの編集なしに入る（`PBXFileSystemSynchronizedRootGroup`）。

## 署名・識別子

チーム ID・バンドル ID・iCloud コンテナは `config/Local.xcconfig`（git 管理外。雛形は `config/Local.example.xcconfig`）に書く。
プロジェクトの全構成が `config/Deck.xcconfig` を土台にし、その末尾で Local.xcconfig を読む（無ければ既定値のまま）。キーの意味は雛形と `mac/README.md`「署名・識別子」。

```sh
cp config/Local.example.xcconfig config/Local.xcconfig   # DEVELOPMENT_TEAM・DECK_BUNDLE_PREFIX・DECK_ICLOUD_CONTAINER を書く
```

- Local.xcconfig が無くてもシミュレータ向けのビルド・テストは通る（バンドル ID は `local.claude-deck.ios`・チーム無し）。実機・TestFlight にはチーム ID が要る。
- Info.plist の URL type の名前は `$(PRODUCT_BUNDLE_IDENTIFIER).pair`、`DeckICloudContainer` は `$(DECK_ICLOUD_CONTAINER)`。
- ペアリングのキーチェーンのサービス名は「バンドル ID + `.pairing`」。バンドル ID を変えると前のペアリングは読めない（ペアリングし直す）。

## 要対応の通知（iCloud）

仕組み・レコードの形・登録の手順は `mac/README.md` の「iPhone への通知（iCloud・CloudKit）」。
- 設定 → 通知「要対応を通知する」（既定は切）: 通知の許可を求め、iCloud のアカウントを確かめ、`registerForRemoteNotifications` してから
  `CKQuerySubscription`（作成時だけ・`attention-notice-created`）を置く。切ると購読を消す。前に出るたびに入っていれば購読を置き直す（同じ ID なので重複しない）。
  許可が無い・iCloud にサインインしていない・購読を作れない時は理由を出す（許可は「設定を開く」）。`ios/ClaudeDeck/Notify/AttentionNotifications.swift`。
- 通知の文: 見出し `title`・本文 `body` をそのまま出す（`ja.lproj/Localizable.strings` の `ATTENTION_TITLE` / `ATTENTION_BODY` = `%@`）。
  同じルームの通知は後から来たもので置き換わる（`collapseIDKey = roomId`）。
- 通知を開く: `DeckAppDelegate` が `ck.qry.af` の `roomId` / `sessionId` を読み、`AppModel.openFromNotice` が一覧のルームへ進む（mac の起動し直しで
  ホスト中のルームの id が替わっていればセッションで辿る）。未接続なら預かって案内を出し、つながって一覧が届いた時に開く（無ければ「見つかりません」）。
- アプリを開いている時は、今見ている会話のルームの知らせは出さない（`AttentionNoticePresentation`）。
- **iCloud（通知）は既定で無効**。iCloud コンテナは作ると削除できないため、通常のビルドはエンタイトルメントを付けない（実機の自動署名がコンテナやプッシュの設定を勝手に登録しないように）。
  有効にする時は、`mac/README.md` の手順でコンテナを作ってから、ターゲットの Build Settings の `CODE_SIGN_ENTITLEMENTS` に `ClaudeDeck.iCloud.entitlements` を設定する（Debug / Release とも）。
- エンタイトルメント `ios/ClaudeDeck.iCloud.entitlements`（`aps-environment`・コンテナ `$(DECK_ICLOUD_CONTAINER)`・CloudKit）。コンテナは Info.plist の `DeckICloudContainer` から読み、空なら「iCloud コンテナが設定されていない」旨を出して入れられない。`CKContainer` は作った時点で無いと落ちるので、作る前に
  実行ファイルの署名（シミュレータ向けは `__TEXT,__entitlements`）からエンタイトルメントを読んで確かめる（`DeckCore` の `ExecutableEntitlements`。
  TestFlight / App Store の版は embedded.mobileprovision を持たないので署名を読む）。無い版では通知を入れられず、設定に理由を出す（入れていた設定は残す）。
- 通知から開くルームを預かるのは 30 分まで（過ぎてからつながっても開かない）。

## ビルド・テスト

```sh
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' test
# 実機向け（署名なしで通るかだけ）
xcodebuild -project ios/ClaudeDeck.xcodeproj -scheme ClaudeDeck -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
# 共有パッケージ
cd packages/DeckCore && swift test
```

画面だけ見たい時は Debug ビルドを起動引数 `-demo rooms` / `-demo conversation` で開く（通信しない見本のデータ）。iPad のシミュレータで開くと 2 列で描く（`-demo conversation` は右に mirio の会話を開いた状態）。

## TestFlight に出す

1. `config/Local.xcconfig` にチーム ID とバンドル ID の頭を書き、Xcode で `ios/ClaudeDeck.xcodeproj` を開いて Signing & Capabilities でチーム・自動署名を確かめる。
   通知（iCloud）を有効にして出す場合だけ、上の手順でエンタイトルメントを設定し、TestFlight 版は CloudKit の **Production** を使うので先に CloudKit Console でスキーマを本番へ反映する（`mac/README.md` の手順 5）。
2. App Store Connect にバンドル ID `<DECK_BUNDLE_PREFIX>.ios` のアプリを作る（無ければ。名前は App Store 全体で一意）。
3. 送るたびに `CURRENT_PROJECT_VERSION` を上げる。Product → Archive → Distribute App → TestFlight & App Store。
4. 輸出規制の質問は Info.plist の `ITSAppUsesNonExemptEncryption = false` で省かれる。外部テスターに配る時は Beta App Review があり、
   審査用のメモに「同じ Wi-Fi の Mac アプリとペアリングして使う。Mac 無しではペアリング画面まで」と書く。
