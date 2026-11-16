# Inbox

[English](README.md) | 日本語

GitHub の通知を Mac で受け取るアプリです。Inbox は GitHub の受信箱を見ていて、レビューの依頼、メンション、自分の Pull Request へのコメントなど、新しいものが届くとバナーで知らせます。バナーをクリックすると、そのスレッドが起きたことの位置でブラウザに開き、既読になります。

Inbox の役目は、届いたらすぐ知らせて、未読を 0 件かそれに近いまま保てるようにすることだけです。検索、絞り込み、多くのスレッドをまとめて扱うこと、Done は [GitHub](https://github.com/notifications) に任せます。ツールバーのボタンからすぐに開けます。

## 動作環境

- Apple シリコンの Mac、macOS 26 以降
- github.com にサインインした [GitHub CLI](https://cli.github.com)

## インストール

1. GitHub CLI をインストールし、サインインします。

   ```sh
   brew install gh
   gh auth login
   ```

2. [Releases](https://github.com/nsuz/mac-inbox/releases) から `Inbox-<version>.dmg` をダウンロードし、Inbox を Applications にドラッグします。
3. Inbox を開きます。インターネットからダウンロードしたアプリを開くかを macOS が確かめてきたら、「開く」をクリックします。
4. Inbox が通知の許可を求めたら、許可します。

## 使い方

- ウィンドウには未読の通知が新しい順に並びます。各行には、そのスレッドが受信箱にある理由と、最後に読んだ後に起きたことが出ます。自分のレビューを待っている Pull Request には印が付きます。
- 行をダブルクリックすると、ブラウザで開きます。スレッドは GitHub 上で既読になります。
- ⇧⌘U を押すと、選んでいる行を開かずに既読にします。選択は次の行に移るので、キーボードで上から順に片付けられます。
- Dock のアイコンに未読の数が出ます。GitHub やほかのアプリで読んだスレッドのバナーは、通知センターから取り下げます。

設定では、どの種類の通知でバナーを出すか（一覧にはすべて出ます）、メニューバーに表示するか、ログイン時に開くかを選べます。

Inbox は英語と日本語に対応していて、Mac の言語に合わせて表示します。Inbox だけ別の言語にするときは、システム設定 > 一般 > 言語と地域 > アプリケーション で選びます。

## 仕組み

Inbox は、起動したときに GitHub CLI でアクティブなアカウントのトークンを GitHub CLI から借ります（`gh auth token`）。トークンを保存することも、新しく作ってもらうこともありません。別のアカウントを使うときは、`gh auth switch` を実行してから Inbox を開き直します。

[通知の API](https://docs.github.com/ja/rest/activity/notifications) を GitHub が求める間隔（ふだんは 1 分に 1 回）で確かめます。条件付きのリクエストなので、変化がなければレート制限を消費しません。各スレッドで何が起きたかは、GitHub の GraphQL API に尋ねます。Inbox が GitHub に書き込むのは既読だけです。通信先は api.github.com だけで、次に起動したときすぐに出せるように、最後の一覧の写しをキャッシュのフォルダに置きます。

## ソースからビルド

Xcode 27.2 以降が必要です。

```sh
open Inbox.xcodeproj
```

`scripts/build-release.sh` は Release 版をビルドし、`.dmg` に包み、`SHA256SUMS.txt` を `dist/` に書き出します。`SIGNING_IDENTITY` に Developer ID を渡さなければ ad-hoc で署名し、`NOTARY_PROFILE` に notarytool のキーチェーンプロファイルを渡せば公証します。

## クレジット

- [swift-subprocess](https://github.com/swiftlang/swift-subprocess)、[swift-system](https://github.com/apple/swift-system)。Apache License 2.0。ライセンスの全文は「Inbox について」にあります。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
