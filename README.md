# Duhcord

A very small native Discord client for macOS. It's written in Swift with AppKit, with no Electron, no web views and no third-party dependencies.

> **Warning:** Duhcord logs in with your user token. Discord's Terms of Service forbid third-party clients and automated user accounts, and accounts have been banned for using them. Use it at your own risk, ideally on an account you can afford to lose.

## What it does

- Three columns: servers, channels and messages, using system fonts and colours, with dark mode.
- Reading and sending messages, with history loaded as you scroll up.
- Unread markers, mention badges, a Dock badge, and notifications for DMs and mentions.
- Markdown rendering for bold, italic, underline, strikethrough, code, code blocks, quotes, spoilers, links, mentions and timestamps.
- Keyboard navigation:

  | Keys | Action |
  |------|--------|
  | ⌘K | Jump to a channel or DM |
  | ⌥↑ / ⌥↓ | Previous / next channel |
  | ⌥⇧↓ | Next unread channel |
  | ⇧↩ or ⌥↩ | Insert a newline in a message |

## What it leaves out on purpose

- Nitro, the shop, Discovery and Activities
- Stickers, soundboard and profile decorations
- The member list and the Friends tab
- Voice and video
- Animated anything

Images and files show up as links and open in your browser. Custom emoji show as `:name:`.

## How it stays light

- It's a native AppKit app with no bundled browser. The app is a few MB.
- It only decodes the gateway event types it uses and drops the rest after reading the header.
- It keeps messages in memory for at most 8 channels, 300 messages each, so memory doesn't grow over time.
- It never loads history in the background. Older messages load only when you scroll up.
- It renders messages with hand-laid-out table cells, and only for the rows on screen.

## Building

You need macOS 13 or newer and Xcode 15 or newer (or the Swift 5.9+ command-line tools).

```sh
swift build            # debug build
swift test             # unit tests for the networking, state and markdown code
scripts/bundle.sh      # release build packaged as build/Duhcord.app
open build/Duhcord.app
```

Every push is built and tested by CI. Each run uploads a ready-made `Duhcord.zip`. The app is ad-hoc signed, so the first time you open it, right-click it and choose **Open**.

## Logging in

Duhcord asks for your token, not your password, so it never handles captchas or 2FA.

1. In the Discord desktop app or the website, open Developer Tools and go to the Network tab.
2. Click any request to `discord.com/api`.
3. Copy the value of its `Authorization` header.

The token is stored only in your login Keychain. **Log Out** in the app menu deletes it.

## Layout

```
Sources/DuhcordCore   Gateway, REST, models, permissions, store and markdown (Foundation only, unit tested)
Sources/Duhcord       AppKit UI
Tests/                Core tests
```
