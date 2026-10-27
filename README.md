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

Link previews, embeds and image attachments are shown inline, built to stay cheap:
- **Preview text is free.** Discord builds link previews on its own servers and sends them inside the message, so Duhcord never visits the linked sites.
- **Images are fetched at display size.** Duhcord only fetches from Discord's image proxy, asking for exactly the size it draws (usually tens of KB). It decodes straight to that size, so the full image is never built.
- **No layout jumps.** Discord sends image sizes up front, so space is reserved before an image arrives.
- **On screen only.** Images load for messages on screen and stop when you scroll away. A small memory cache that macOS can empty holds them, and nothing is saved to disk.
- **No playback.** Videos and GIFs show a still frame with a ▶ that opens the original.
- **Your choice.** Spoilers wait for a click. **Settings → Images** switches between Always, Click to load and Off.

Other files show up as links that open in your browser. Custom emoji show as `:name:`.

## How it stays light

- It's a native AppKit app with no bundled browser. The app is a few MB.
- It only decodes the gateway event types it uses and drops the rest after reading the header.
- It keeps messages in memory for at most 8 channels, 300 messages each, so memory doesn't grow over time.
- It never loads history in the background. Older messages load only when you scroll up.
- It renders messages with hand-laid-out table cells, and only for the rows on screen.

## Security

- The release app runs in the **App Sandbox** and its only permission is making outgoing network connections (see `Duhcord.entitlements`). It can't read your files, use the camera, microphone, contacts or location, accept incoming connections, or control other apps.
- It's signed with the **hardened runtime** and no exceptions: no JIT, no unsigned code, no injected libraries, no debugger attachment.
- CI runs `scripts/verify-bundle.sh` on every build and fails if either protection is missing or the app gains a permission beyond that file.
- Your token is stored only in the Keychain (readable only while your Mac is unlocked, this device only, never synced) and is sent only to Discord.
- All network traffic goes through one hardened connection layer (`SecureSession`):
  - it only connects to `discord.com` and `*.discord.gg` (images: only Discord's image proxies, without the token);
  - certificates must chain to Apple's built-in roots, so interception tools that add their own root certificate are refused;
  - redirects are refused, so the token can never be forwarded to another host;
  - nothing is cached or written to disk.
- Links in messages only open if they're `http`/`https`.
- It has no third-party dependencies.

Both protections are enforced by macOS when the app starts. They add no memory, CPU or disk cost.

## Building

You need macOS 13 or newer and Xcode 15 or newer (or the Swift 5.9+ command-line tools).

```sh
swift build            # debug build
swift test             # unit tests for the networking, state and markdown code
scripts/bundle.sh      # release build packaged as build/Duhcord.app (sandboxed, hardened runtime)
open build/Duhcord.app
```

Every push is built and tested by CI. Each run uploads a ready-made `Duhcord.zip`.

## Release signing

Release builds are signed with the self-signed **Duhcord Release Signing** certificate. Builds of other branches, pull requests and local builds without the certificate are signed ad-hoc.

macOS doesn't know this certificate, so the first launch of a downloaded copy still needs approval:
- **macOS 15 and later:** open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
- **macOS 13–14:** right-click the app and choose **Open**.

What the certificate gives you:
- **Updates keep the same identity.** The Keychain keeps trusting new versions, so updates don't keep asking for access to your login.
- **You can check a download is genuine.** Its certificate fingerprint must match `signing/certificate.sha256`:

  ```sh
  cd /tmp && codesign -d --extract-certificates /Applications/Duhcord.app && shasum -a 256 codesign0
  ```

CI refuses to publish a release build signed by any other certificate.

### Setting up the certificate (maintainer, once)

1. On your Mac, run `scripts/create-signing-certificate.sh` from the repo and choose a strong password.
   It creates the certificate, adds it to your login keychain, and writes everything to `~/Duhcord-signing`.
2. Back up `~/Duhcord-signing/duhcord-signing.p12` and its password somewhere offline. Without them, future releases can't use the same identity.
3. Add two secrets on GitHub under **Settings → Secrets and variables → Actions → New repository secret**:
   - `DUHCORD_SIGNING_P12`: the entire contents of `~/Duhcord-signing/duhcord-signing.p12.base64` (`pbcopy < ~/Duhcord-signing/duhcord-signing.p12.base64` copies it).
   - `DUHCORD_SIGNING_PASSWORD`: the password from step 1.
4. Commit the fingerprint from `~/Duhcord-signing/fingerprint.txt` as `signing/certificate.sha256`.
5. Push to the default branch. The CI log should say "signed by the published Duhcord Release Signing certificate".

Never commit or share the `.p12` file, its `.base64` copy or the password. The fingerprint and `certificate.pem` are public.

## Updates

Duhcord checks GitHub for a new release shortly after launch and then once a day. Turn this off under **Settings → Updates**, or check by hand with **Duhcord → Check for Updates…**. When an update is available, a bar appears at the top of the window. Nothing is installed until you click **Update…**, and Duhcord relaunches when it's done.

Duhcord can only update itself from your Applications folder (`/Applications` or `~/Applications`). Run from anywhere else, it shows an orange bar asking you to move it.

How updates are checked:
- Every release's `update.json` is signed with the **update approval key**. Duhcord only accepts updates signed by a key built into it, and only if the version is newer than the installed one.
- The download must match the size and SHA-256 in the signed `update.json`.
- The update check uses its own connection: GitHub only, never the Discord token, Apple root certificates only.
- A small installer helper inside the app (`Sources/DuhcordUpdater`) does the install, because a sandboxed app can't replace itself. Before swapping the new version in atomically, it repeats every check above. It also requires that the new app:
  - is signed with the same certificate,
  - still has the sandbox and hardened runtime,
  - has no permissions beyond Duhcord's.

  It only accepts requests from Duhcord, has no network access, and runs only during an install.

### Setting up the update approval key (maintainer, once)

1. On your Mac, from the repo folder, run:
   ```sh
   swift scripts/create-update-key.swift
   ```
   It writes `~/Duhcord-signing/update-key.private` and `update-key.public`, and prints the public key.
2. Back up `update-key.private` offline, next to your signing certificate. If it's lost, installed copies can't verify new updates and need one manual reinstall.
3. Add a repository secret named `DUHCORD_UPDATE_KEY` under **Settings → Secrets and variables → Actions**, containing the private key (`pbcopy < ~/Duhcord-signing/update-key.private` copies it).
4. Add the public key to `trustedPublicKeys` in `Sources/DuhcordUpdateKit/UpdateKit.swift` and push.

### Publishing a release

```sh
git tag -a v1.2.0 -m "What changed in this version"
git push origin v1.2.0
```

The release workflow:
1. builds and signs the app,
2. writes and signs `update.json`, using the tag message as the release notes,
3. publishes a GitHub release with `Duhcord.zip`, `update.json` and `update.json.sig`.

It refuses to publish if the key's public half isn't built into the app.

## Logging in

Duhcord only logs in by QR code, the same way the official desktop app does. You can't type or paste a password or token.

1. Duhcord shows a QR code.
2. On your phone, open Discord and go to **You → Settings → Scan QR Code**.
3. Approve the login on your phone.

For each login attempt, Duhcord makes a new encryption key that exists only in memory. Discord sends the token encrypted to that key, and the key is thrown away once the attempt ends. Only scan codes from a Duhcord window you opened yourself.

**Log Out** deletes the token from the Keychain and also logs it out on Discord's side, so any copy of it stops working.

## Layout

```
Sources/DuhcordCore       Gateway, REST, models, permissions, store, markdown, update checks (unit tested)
Sources/DuhcordUpdateKit  Update manifest and signature checks, shared with the installer helper
Sources/DuhcordUpdater    The installer helper (XPC service)
Sources/Duhcord           AppKit UI
Tests/                Core tests
```
