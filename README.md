# Claude使用量モニター（ClaudeUsageBar）

Macのメニューバーに常駐して、Claudeの使用量を常に表示するアプリです。
「気づいたら制限を超えて追加課金されていた」を防ぎます。

Claude Chat・Claude Code・Coworkはアカウント単位で使用量枠を共有しているため、このアプリの数値はどのツールから使った分も合算されています。

## できること

| 機能 | 内容 |
|---|---|
| メニューバー表示 | 「5h ◯%｜W ◯%」で5時間枠・週間の使用率を常時表示（緑→橙→赤で色が変わる／100%超は⚠マーク） |
| パネル表示 | メニューを開くとリンググラフで詳細（5時間枠・週間・Sonnet/Opus/Cowork個別枠・追加課金額） |
| 制限アラート | 5時間枠・週間制限（全体・Sonnet・Opus・Cowork）が **80% / 95% / 100%** になったら通知 |
| 従量課金アラート | 追加課金（従量課金）が発生した瞬間に通知 |

## ⚠️ 配布される方へ：必須の前提条件

**このアプリを使うには、そのMacで一度 Claude Code（CLI）にログインしている必要があります。**
ブラウザ版のClaude ChatやCoworkだけ使っていて、ターミナルでClaude Codeを使ったことがない場合、このアプリは動作しません（「認証情報が見つかりません」と表示されます）。

まだの人は、ターミナルで以下を実行してログインしてください（一度だけでOK）。

```bash
claude
```

表示に従ってログインが完了すれば準備完了です。ふだんCLIを使う予定がなくても、このログインだけしておけば大丈夫です。

## インストール方法

1. 上記の「必須の前提条件」を済ませる
2. [Releases](../../releases/latest) から `ClaudeUsageBar.zip` をダウンロードして解凍する
3. 出てきた `ClaudeUsageBar.app` を「アプリケーション」フォルダにドラッグする
4. ダブルクリックで起動する
   - 署名・公証済みアプリなので「"ClaudeUsageBar"はインターネットからダウンロードされたアプリです。開いてもよろしいですか？」という穏やかな確認だけで開けます。「開く」を押してください
5. 起動時に2つの許可を求められます:
   - **キーチェーンへのアクセス** → 「**常に許可**」（使用量の取得に必要。ログイン情報を読むだけで外部には送りません）
   - **通知の許可** → 「**許可**」
6. メニューバーに「**Claude 5h ◯% | W ◯%**」と出たら完了
7. メニューを開いて「**ログイン時に自動起動**」をONにしておくのがおすすめ

## 通知が来たらどうすればいい？

### 🟡「5時間枠を80%使いました」と来たら
急ぎでない作業は、通知に書いてあるリセット時刻の後に回しましょう。

### 🚨「上限に達しました」「追加課金が発生しています」と来たら
そのまま使い続けると従量課金（追加料金）になります。リセット時刻まで待つのが安全です。

## しくみ（気になる人向け）

- 使用量: Claude Codeの `/usage` コマンドと同じAPIを5分ごとに確認
- ログイン情報はこのMacの中だけで使い、Anthropicのサーバー以外には一切送信しません
- Claude Code CLIとClaude Desktop/Coworkは認証の仕組みが別なので、Coworkだけを使っている人はCLIへのログインが別途必要です（上記「必須の前提条件」）

## 開発者向け：ソースからビルドする場合

Xcode（またはCommand Line Tools）だけあれば、ad-hoc署名でビルドできます（配布用の署名・公証はスキップされます）。

```bash
./build.sh          # build/ClaudeUsageBar.app が出来る
./install.command    # ビルドして /Applications にインストール・起動まで自動
```

配布用に署名・公証したい場合は、Apple Developer Program（Developer ID Application証明書）が必要です。

1. `cp build.local.sh.example build.local.sh`
2. `build.local.sh` を自分の証明書名・公証プロファイル名に書き換える（このファイルはgitignore対象です）
3. `./build.sh` を実行すると、ビルド→署名→公証→stapleまで自動で行われます（公証待ちで数分かかります）

設定を変えたいときは [Sources/main.swift](Sources/main.swift) 先頭の `Config` を編集してから再ビルドしてください。

### 配布用zipの作り方

```bash
./build.sh
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/ClaudeUsageBar.app dist/ClaudeUsageBar.zip
```

`dist/ClaudeUsageBar.zip` を配布してください。

## アンインストール

メニューから「終了」→「アプリケーション」フォルダの ClaudeUsageBar.app をゴミ箱へ。
