# Inbox

English | [日本語](README.ja.md)

GitHub notifications on your Mac. Inbox watches your GitHub inbox and shows a banner when something new arrives: a review request, a mention, a comment on your pull request. Click the banner and the thread opens in your browser, right at what happened, and is marked as read.

Inbox does one job: telling you as things arrive, so you can keep your unread notifications at zero or close to it. Searching, filtering, working through many threads at once and Done stay on [GitHub](https://github.com/notifications), one click away from the toolbar.

## Requirements

- macOS 26 or later on Apple Silicon
- [GitHub CLI](https://cli.github.com), signed in to github.com

## Install

1. Install GitHub CLI and sign in:

   ```sh
   brew install gh
   gh auth login
   ```

2. Download `Inbox-<version>.dmg` from [Releases](https://github.com/nsuz/mac-inbox/releases) and drag Inbox to Applications.
3. Open Inbox. If macOS says it can’t verify the app, open System Settings > Privacy & Security and click Open Anyway. You only need to do this once.
4. Allow notifications when Inbox asks.

## Use

- The window lists your unread notifications, newest first. Each row says why the thread is in your inbox and what happened since you last read it, and marks pull requests waiting for your review.
- Double-click a row to open it in your browser. The thread is marked as read on GitHub.
- Press ⇧⌘U to mark the selected row as read without opening it. The selection moves to the next row, so you can work down the list from the keyboard.
- The Dock icon shows how many notifications are unread. Banners for threads you have read anywhere, on GitHub or in another app, are taken back.

In Settings, choose which kinds of notifications show a banner (Inbox still lists every one), show Inbox in the menu bar, and open it at login.

Inbox speaks English and Japanese, following your Mac’s language. To use a different one for Inbox alone, choose it in System Settings > General > Language & Region > Applications.

## How it works

Inbox borrows the token GitHub CLI already has (`gh auth token`) for the account active when Inbox starts. It never stores the token and never asks you to create one. Run `gh auth switch` and reopen Inbox to use another account.

It checks the [notifications API](https://docs.github.com/en/rest/activity/notifications) as often as GitHub asks (usually once a minute) with conditional requests, which don’t count against your rate limit when nothing has changed, and asks GitHub’s GraphQL API what happened on each thread. The only thing Inbox writes to GitHub is marking threads as read. It talks to nothing but api.github.com, and keeps a copy of the last list in its caches folder so that it shows up at once on the next launch.

## Build from source

Xcode 27.2 or later is required.

```sh
open Inbox.xcodeproj
```

`scripts/build-release.sh` builds a Release app, wraps it in a `.dmg` and writes `SHA256SUMS.txt` into `dist/`. It signs ad hoc unless `SIGNING_IDENTITY` names a Developer ID, and notarizes when `NOTARY_PROFILE` names a notarytool keychain profile.

## Credits

- [swift-subprocess](https://github.com/swiftlang/swift-subprocess) and [swift-system](https://github.com/apple/swift-system), Apache License 2.0. Their notices are in About Inbox.

## License

MIT. See [LICENSE](LICENSE).
