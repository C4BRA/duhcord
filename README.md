# Duhcord

A small, native Discord client for macOS, written in Swift with AppKit: no Electron, no web views. Apple silicon only.

> **Warning:** Duhcord logs in with your user token. Discord's Terms of Service forbid third-party clients, and accounts have been banned for using them. Use it at your own risk, ideally on an account you can afford to lose.

## Features

- **A Mac-style window**, laid out like Mail: a server sidebar, the channel list, and messages, under a unified toolbar showing the channel's name and topic. It uses system fonts, colours and controls, so dark mode, accent colours and accessibility settings just work.
- **Messages:** reading and sending, history loaded as you scroll up, and Markdown (bold, italic, underline, strikethrough, code, quotes, spoilers, links, mentions, timestamps). Each conversation keeps its own unsent draft (and a DM keeps separate ones for Standard and Private), and a message that fails to send goes back to the conversation it was written in.
- **Sending images and videos:** drop images or videos onto a conversation or paste them (up to 4 per message). They wait in a row above the message box, where ✕ takes one out before you send. Each is re-encoded from its pixels first, so nothing else in the file (location, camera details, edits) goes to Discord, and it's uploaded as `image.jpg` or `image.png`, not under its own name. Pressing Return while one is still being prepared sends once it's ready. Animated GIFs go as their first frame.
  - **Videos** are written to a new file in memory with only their picture and sound, so their location and other details stay behind too. With **Settings → Videos → Compress to fit my upload limit** (on by default), one that's too large for your account's limit (read from your Nitro tier: 10 MB without Nitro, 50 MB with Nitro Basic, otherwise up to Duhcord's own 100 MB cap) is re-encoded with the Mac's hardware encoder. The bitrate is worked out from its length, the resolution suits that bitrate, and it's capped at 30 fps; if the encoder lands over, it tries again lower. A video that already fits is only repackaged, at its own quality. One too long to stay watchable (under about 0.2 Mbit/s) is refused, with how long a video can be. The row shows its progress, and ✕ stops it. Videos go as H.264, which every Discord app plays, and as HEVC in Private.
- **Unread markers, mention badges** (in the sidebar and on the Dock icon), and notifications for DMs and mentions. Click a notification to open its conversation.
- **Right-click menus** on messages (Copy Text, Copy Message Link, the author's profile; on your own, **Remove Image…** to take one image out of a sent message for everyone, and **Delete Message…**), channels and servers (Mark as Read, Copy Link), and people in voice channels (Show Profile, Message).
- **Search** (⌘F, in the toolbar) shows only the loaded messages in the conversation that match.
- **Images, GIFs, videos and link previews** shown inline. Spoilers wait for a click, and **Settings → Images** can switch images to click-to-load or off.
- **Profile pictures and server icons**, loaded at exactly the size shown.
- **Profiles:** click someone's name or picture in a chat, or their name in a voice channel, for a card with their banner, picture, status, bio, roles, mutual friends and servers, and a box for sending them a quick message. Click the picture on the card for their full profile: what they're doing now, their profile board (favorite games and the like), and lists of mutual friends and servers.
- **Typing tabs:** when someone types, a tab with their picture rises from behind the message box. It sinks halfway when they stop and leaves a minute later. VoiceOver announces who's typing instead.
- **Voice channels**, end-to-end encrypted (see [Voice](#voice)).
- **QR-code login**, the same way the official desktop app logs in (see [Logging in](#logging-in)).

| Keys | Action |
|------|--------|
| ⌘K | Jump to a channel or DM |
| ⌘F | Search the conversation |
| ⌥⌘P | Switch a DM between Standard and Private |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next channel |
| ⌥⇧⌘↓ | Next unread channel |
| ⇧⌘M / ⇧⌘D | Mute / deafen in a call |
| Return | Join the selected voice channel, or open the selected person's profile |
| ⌃⌘S | Show or hide the sidebar |
| ⇧↩ or ⌥↩ | New line in a message |

**Left out on purpose:** Nitro, the shop, Discovery, Activities, stickers, the soundboard, profile decorations, the member list, the Friends tab, video, screen sharing and DM calls. Animated profile pictures and icons show as stills, and custom emoji show as `:name:`.

## Voice

Voice channels in the channel list show who's in them, with a green ring around whoever is talking. Click a channel to join it. The bar at the bottom of the channel list and the toolbar both have mute, deafen and disconnect. Click **Voice Connected** to see the server, ping, packet loss and whether the call is end-to-end encrypted. **Show advanced details** adds everything else, including the call's privacy code. Duhcord only measures these while that window is open.

- **End-to-end encrypted.** Calls use Discord's DAVE protocol through Discord's own open-source library, libdave, so Discord's servers relay the audio without being able to hear it. Nothing you say is sent until the bar shows **End-to-End Encrypted**.
- **Kept away from your login.** Calls run in a separate helper process, sandboxed on its own with only network and microphone access. It gets a voice token that's good for one call, never your account token. libdave is C++, and running it there keeps any bug in it away from your login.
- **The microphone is only open while you're unmuted.** Muting closes it, so macOS's microphone indicator turns off. Deafening stops all audio. The helper exits when you leave.
- **Light on resources.** macOS encodes and decodes the audio (Opus) and handles echo and noise (Apple's voice processing). Nothing is sent while you're quiet. A call uses about 64 kbit/s up while you talk, plus about 64 kbit/s down per person talking.

## Private messaging

DMs between Duhcord users can be end-to-end encrypted, so Discord only ever stores scrambled text. Switch a DM from **Standard** to **Private** in the toolbar (or **View → Private Messages**, ⌥⌘P). The Private view lists only the private messages; the standard view folds them to one line.

- **Setting up.** The first time, Duhcord sends the other person a short handshake message carrying your key. If they use Duhcord, it offers them private chat; once they accept, their app answers with their key and you can start. On other apps the handshake and private messages show a note instead.
- **How it's encrypted.** Each Duhcord install has a key pair (X25519) kept in your login keychain. Each message's key is derived from your key and a random value, so you can read messages Discord attributes to you, and reaches the other person through HPKE (RFC 9180) in authenticated mode, so it can only have come from you; it's tied to that DM. The text is compressed, padded so its length gives little away, and encrypted with ChaCha20-Poly1305. Nothing else is stored: history loaded from Discord later decrypts again.
- **Fitting in a message.** Discord counts a message's length in UTF-16 units, so the encrypted data is written with CJK and Hangul characters that carry 15 bits each, about 2.5 times what base64 fits. With compression, a private message holds more than a plain one: roughly 3,000 characters of hard-to-compress text, and much more ordinary prose, within the non-Nitro 2,000-character limit. Other apps show it as a line of small grey text ("encrypted messaging by C4BRA/duhcord") above a block of those characters.
- **Which keys get your messages.** Discord carries the keys, so it could slip in one of its own. No key receives your messages until it's trusted:
  - The other person's first key is trusted on first use. A later one (a new Mac, a reinstall, or someone in the middle) waits: Duhcord shows the safety number it would make, and you accept or reject it. Until then your messages go only to the keys you already accepted, and anything sent from the new key is marked.
  - Your own other Macs appear in **Settings → Private messages**, under **This Mac (main)**. A new one is greyed out and gets nothing until you approve it; check that its 30-digit code matches the one under "This Mac" in Duhcord's Settings on that Mac. Denials are remembered. Up to three other Macs can be approved.
  - A message is never quietly left without one of its keys: if one would go to too many, Duhcord says so instead of sending.
- **Accepting exactly what you compared.** Accepting a new key, or marking a chat verified, covers only the keys and the number you were shown. If a key arrives while the sheet is open, it stays waiting and nothing is marked verified.
- **Checking.** Compare the **safety number** with the other person, in person or in a voice call, and mark it verified. It covers every key on both sides, so it only matches when both your Duhcords encrypt to exactly the same Macs. "Verified" holds for those keys only: if either of you adds or removes a Mac, compare again. Comparing is up to you; private chat works either way.
- **Images and videos.** Images and videos sent in Private (see [Sending images and videos](#features)) are encrypted too. A private video waits for a click, then downloads, decrypts and plays from memory (up to 50 MB each); its first frame stays afterwards. Each one is re-encoded and sized so four fit Discord's 10 MB upload limit, then encrypted with a key of its own (ChaCha20-Poly1305), padded so its size says little (Padmé), and uploaded as a file called `encrypted.bin`; its key travels inside the private message. Discord only stores noise. Duhcord downloads it from Discord's file CDN, decrypts it, and shows it inline; click it for a full-size window, where ⌘C copies it. Images are kept in memory only, and their windows close when Duhcord locks or the account logs out. **Remove Image…** on your own private message seals its text again without that image's key and deletes the encrypted file.
  - These are the one kind of picture Duhcord decodes without Discord re-encoding it first, so it's limited to images sent from keys you trust (an accepted key, or one of your approved Macs), to JPEG and PNG, and to the same size limits as other images. Images from a key you haven't accepted aren't downloaded.
  - There's no attach button or Save: Duhcord's sandbox doesn't let it open or write files. Dropped and pasted images don't need that permission. Copied images go on the clipboard, which Universal Clipboard can share with your other Apple devices.
- **Limits.** One-to-one DMs only; text, still images and videos, no other files (animated GIFs are sent as their first frame). Discord still sees who you talk to and when. Private messaging needs macOS 14 or later, and private messages can't be read on Discord's own apps, including yours. There is no forward secrecy: a later compromise of a Mac's key can decrypt its stored message history. Authenticated HPKE has key-compromise impersonation: someone with your private key could forge messages to you that appear to come from your contacts.

## How it stays light

- It's a native app of a few MB, with no bundled browser.
- The live connection is compressed (`zlib-stream`, usually 3–10× smaller) and unpacked by macOS's built-in Compression framework. A single decompressed message is capped at 128 MB.
- It only decodes the events it uses.
- It keeps messages for at most 8 channels, 300 each, so memory stays flat. History never loads in the background.
- If Discord can't be reached, an offline bar leaves loaded messages readable while Duhcord reconnects automatically. Retries back off up to a minute and happen immediately when the network returns.
- Messages are laid out by hand, and only for the rows on screen.
- Images come from Discord's image proxy at exactly the size drawn and are decoded straight to that size. They load only while on screen and are kept in a small memory cache, never on disk. Link previews come inside messages, so Duhcord never visits linked sites, and activity pictures hosted elsewhere (Spotify, YouTube, Twitch) aren't loaded.
- GIFs animate on hover (or while visible, under **Settings → Animate GIFs**), a few at a time, and only while Duhcord is in front. Videos play on click, one at a time, with a few seconds buffered.

## Security

- **App Sandbox and hardened runtime, with no exceptions.**
  - The app can only make outgoing network connections (`Duhcord.entitlements`).
  - The voice helper can also use the microphone (`DuhcordVoice.entitlements`).
  - The installer helper has no entitlements at all.
  - CI's `scripts/verify-bundle.sh` fails the build if any of these change, or if a binary isn't arm64-only.
- **Your token is only in your login Keychain, and only ever sent to Discord.**
- **Discord's data collection is switched off.** With **Settings → Privacy → Limit what Discord collects** (on by default), Duhcord turns off each account's data and marketing settings once, the same switches Discord's own app offers: using your data for usage statistics and personalisation, screen reader tracking, game and platform account detection, contact and phone number matching, being found by phone or email, and marketing emails. Duhcord itself never sends Discord's analytics or crash reports.
- **One locked-down connection layer** (`SecureSession`) carries all traffic:
  - It connects only to Discord's hosts (`discord.com`, `*.discord.gg`; images from Discord's proxies and its CDN's profile picture, banner, icon and badge paths; voice from `*.discord.media`).
  - Certificates must chain to Apple's built-in roots, so interception tools that install their own root are refused.
  - Redirects are refused.
  - Nothing is cached to disk.
- **Links** only open if they're `http` or `https`. Suspicious ones get a warning first (login-page look-alikes, OAuth grants, links whose text shows a different site).
- **Third-party code** is limited to libdave and its dependencies (mlspp, BoringSSL, nlohmann/json). It's built from source at pinned commits and linked only into the voice helper. Their licences are in `Duhcord.app/Contents/Resources/Licenses`.

## Logging in

Duhcord only logs in by QR code; you can never type or paste a password or token.

1. Duhcord shows a QR code.
2. In Discord on your phone, go to **You → Settings → Scan QR Code**.
3. Approve the login on your phone.

Each attempt uses a new encryption key that exists only in memory. Discord sends the token encrypted to it, and the key is discarded afterwards. Only scan codes from a Duhcord window you opened yourself.

**Log Out** revokes the token on Discord's side before deleting it from the Keychain. If Discord can't be reached, Duhcord stays locked rather than leaving a working token behind.

### More than one account

**Duhcord → Switch Account → Add Account…** logs in another account by QR code, up to five, as in Discord's own app. Switch between them from the same menu (⌃⌘1 to ⌃⌘5) or in **Settings**. One account is connected at a time: switching ends any call and connects the other account, which takes a moment. Each account's token is its own Keychain item, and **Log Out** (in the menu, or per account in Settings) revokes only that account's token. Discord can tell that accounts used from the same Mac belong together, as it can with its own app.

## Updates

Duhcord checks GitHub for a new release shortly after launch and then once a day; turn this off under **Settings → Updates**. When one is available, an **Update** button appears in the toolbar. Nothing installs until you confirm, and Duhcord then relaunches.

`update.json` carries an expiry that the refresh workflow renews monthly. If it expires, Duhcord says it couldn't confirm it's up to date; it still offers a newer signed version.

It can only update itself from `/Applications` or `~/Applications`. Anywhere else, a bar under the toolbar asks you to move it.

How an update is checked:
- `update.json` must be signed with the update approval key built into Duhcord, and the version must be newer.
- The download must match the size and SHA-256 in `update.json`.
- An installer helper (`Sources/DuhcordUpdater`) repeats every check, then swaps the new version in atomically. It also requires the new app to:
  - carry the same signing certificate,
  - keep the sandbox and hardened runtime,
  - have no permissions beyond Duhcord's (for the app and both helpers).

  It only accepts requests from Duhcord and has no network access.

## Building

You need an Apple silicon Mac with macOS 13 or newer, and Xcode 15+ (or the Swift 5.9 tools) plus CMake for libdave.

```sh
swift build              # debug build (the voice helper is included once libdave is built)
swift test               # unit tests
scripts/build-libdave.sh # build libdave for the voice helper (bundle.sh runs it too)
scripts/bundle.sh        # release build: build/Duhcord.app
open build/Duhcord.app
```

`bundle.sh` also looks up Discord's current build number and desktop version (`scripts/discord-build-info.sh`), so Duhcord describes itself to Discord the way the official Mac app does. Without network access it falls back to the values built into `ClientIdentity`.

CI builds and tests every push and uploads a ready-made `Duhcord.zip`.

## Release signing

Release builds are signed with the self-signed **Duhcord Release Signing** certificate; other builds are signed ad-hoc. macOS doesn't know this certificate, so allow the first launch of a download:
- **macOS 15 and later:** open it once, then click **Open Anyway** in **System Settings → Privacy & Security**.
- **macOS 13–14:** right-click the app and choose **Open**.

The certificate keeps updates on the same identity, so the Keychain doesn't ask again. To check that a copy is genuine, its fingerprint must match `signing/certificate.sha256`:

```sh
cd /tmp && codesign -d --extract-certificates /Applications/Duhcord.app && shasum -a 256 codesign0
```

### Maintainer setup (once)

**Signing certificate:**
1. Run `scripts/create-signing-certificate.sh` and choose a strong password. Everything goes to `~/Duhcord-signing`.
2. Back up `duhcord-signing.p12` and its password offline.
3. Add the repository secrets `DUHCORD_SIGNING_P12` (the contents of `duhcord-signing.p12.base64`) and `DUHCORD_SIGNING_PASSWORD`.
4. Commit `fingerprint.txt` as `signing/certificate.sha256`.

**Update approval key:**
1. Run `swift scripts/create-update-key.swift`. It writes `~/Duhcord-signing/update-key.private` and `.public`.
2. Back up the private key offline. If it's lost, installed copies need one manual reinstall.
3. Store `DUHCORD_UPDATE_KEY` as a secret of a GitHub Environment named `release` (Settings → Environments → release). Add required reviewers and limit deployments to tags `v*`.
4. The release workflow's publish job is the only job that uses it. No third-party source is built in that job.
5. Add the public key to `trustedPublicKeys` in `Sources/DuhcordUpdateKit/UpdateKit.swift`.

Never commit or share the `.p12`, its `.base64` copy, its password, or `update-key.private`.

### Publishing a release

```sh
git tag -a v1.2.0 -m "What changed in this version"
git push origin v1.2.0
```

The release workflow builds and tests without signing credentials. The publish job waits for approval in the `release` environment, then signs the app and `update.json` (with the tag message as release notes) and publishes the GitHub release. It refuses tags that aren't on the default branch, and update keys that installed copies wouldn't trust.

## Layout

```
Sources/Duhcord           AppKit UI
Sources/DuhcordCore       Gateway, REST, models, permissions, store, markdown, update checks
Sources/DuhcordVoice      Voice helper (XPC service): voice gateway, UDP audio, DAVE, Opus
Sources/DuhcordVoiceKit   Voice helper protocol, packet format, transport encryption
Sources/CDave             libdave's C header (the library comes from scripts/build-libdave.sh)
Sources/DuhcordUpdater    Installer helper (XPC service)
Sources/DuhcordUpdateKit  Update manifest and signature checks, code-signature checks
Tests/                    Unit tests
```
