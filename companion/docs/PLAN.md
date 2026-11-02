# Duhcord Private Companion + thin plugins for Vencord, Replugged, BetterDiscord

Goal: people on Vencord (and Vesktop), Replugged and BetterDiscord can chat in Duhcord's Private mode with Duhcord
users, and Discord (its servers *and* its app) never holds their key or the decrypted text. Duhcord users decide
whether they chat privately with these clients at all.

Facts checked against the source (Nov 2026 HEADs of each project) are marked ✔; anything still unverified is
marked **(verify)**.

---

## 1. Architecture

```
 ┌───────────── Discord desktop (Electron, Discord's code + the mod) ─────────────┐
 │  Thin plugin (Vencord / Replugged / BD)                                         │
 │   • spots private messages (dhc2:) and hands the ciphertext to the companion   │
 │   • posts / edits / deletes what the companion gives it                         │
 │   • shows a "🔒 Private" toolbar button and folds ciphertext to one line        │
 │   • (frame mode) embeds the companion's cross-origin frame over the chat        │
 └───────────────▲─────────────────────────────────────────────────────────────────┘
                 │  bridge: WebSocket on 127.0.0.1, ciphertext + metadata only
 ┌───────────────┴──────────── Duhcord Private Companion (separate process) ───────┐
 │  Rust core: keys, trust directory, seal/open, safety numbers, replay checks     │
 │  OS key store (Credential Manager / Keychain / Secret Service)                  │
 │  UI: Private window per DM (default), optional inline frame served on loopback  │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

**Invariant (enforced by the bridge schema and tests):** no key and no plaintext ever crosses the bridge, in either
direction. The companion seals only text typed in its own UI. So a hijacked plugin, a malicious plugin update, or
Discord's own JS can do no more than Discord can today: drop, delay or replay messages. Duhcord's existing replay
check (10-minute "sent at" window plus duplicate salt) catches the replays.

Every Discord message is still sent through Discord's own client, using the plugin. The companion never sees the
Discord token.

### Two ways to show the chat

| Mode | Where plaintext lives | Protects against | Doesn't protect against |
|---|---|---|---|
| **Window** (default) | Companion's own window (separate OS process) | Discord servers; Discord's page JS; Discord's main process acting as a normal app (it has no route to the window or the key through Electron); malicious plugin updates | Native code running as the same user, *deliberately* reading the OS key store or the companion's memory. On Windows/Linux that includes a deliberately malicious Discord desktop build (Credential Manager and Secret Service don't limit items to one app). On macOS the Keychain limits the item to the companion's signature, and reading another app's memory is blocked without special entitlements. |
| **Inline frame** (opt-in) | A cross-origin iframe (`http://127.0.0.1:<port>`) the plugin places over the chat | Discord servers; Discord's page JS (the code Discord changes without app updates); plugin updates | Discord's main process (it can reach every frame in its windows through Electron); a fake look-alike composer drawn by Discord's page (mitigated by a per-install secret shown only in the real frame, see §3.5) |

---

## 2. Duhcord changes (Swift, ships first)

1. **Handshake `0x23`** (new type):
   `23 | flags (1: wantsReply) | client class (1) | host (1) | features (2) | key (32)` = 38 bytes.
   - Client class: `1` = Duhcord Private Companion. Host: `1` Vencord, `2` Vesktop, `3` Replugged, `4` BetterDiscord.
     It's shown in the UI and lets us tune things per mod later.
   - Features: bit 0 text, bit 1 images, bit 2 single videos, bit 3 reels.
   - ✔ Current and older Duhcord builds only accept a handshake that is exactly 34 bytes with type `0x22`
     (`PrivateMessaging.kind`), so they ignore 0x23. They fail closed.
   - Duhcord keeps sending the 34-byte 0x22 handshake. The companion reads it as "Duhcord, every feature".
2. **Settings → Privacy → Private messages → "Private chat with Duhcord Companion": Off by default.**
   - When it's off, a 0x23 request shows a one-line note ("…uses Duhcord Companion on BetterDiscord. Private chat
     with Companion is off in Settings") and is never answered.
3. **Companion keys are never trusted on first use.** Each goes through the accept sheet, which explains the gap:
   "Their messages are decrypted by a separate app on a Windows/Linux PC. Duhcord's Apple security features don't
   protect that side." The person can still compare safety numbers.
4. **The label only gets weaker.** Once a key has been seen in a 0x23 handshake, it stays a companion key, and a later
   0x22 handshake for the same key can't relabel it as Duhcord.
5. **Safety number v3 covers each key's client class.** If Discord strips the label (rewrites 0x23 as 0x22), the two
   sides' numbers stop matching. A v2 number is kept for Duhcord↔Duhcord pairs, so their existing verifications stay
   valid.
6. **Per-DM "Only their Duhcord Macs" switch.** It keeps companion keys out of one conversation even when the person
   also has a Mac. The toolbar badge shows "Private · Companion" whenever a companion key receives your messages.
7. **Companion keys can't be approved as one of your Macs** (they're never added to `devices`).
8. **Feature gating.** Attach is turned off, with a reason, while any recipient key lacks the needed feature bit.
   Incoming media from a key that lacks the bit is handled as it is today.
9. **Test vectors:** a `PrivateVectorTests` target writes fixed keys, handshakes, sealed messages (text,
   compressed/uncompressed, files), safety numbers and key codes to `Tests/Vectors/*.json` for the companion CI.

Release order: this Duhcord version has to be published (and auto-updated to users) before any companion or plugin
release. Nothing here changes entitlements, so the updater-allowlist trap from earlier releases doesn't apply.

---

## 3. The companion

### 3.1 Stack
- **Rust workspace** in `companion/`:
  - `protocol`: wire format.
    - Crates: `hpke` (auth mode, X25519-HKDF-SHA256 / ChaCha20-Poly1305), `x25519-dalek`, `chacha20poly1305`,
      `hkdf`, `sha2`, and `miniz_oxide` for raw DEFLATE (✔ Duhcord uses Apple `COMPRESSION_ZLIB`, which is raw
      DEFLATE, with a 64 KiB cap on what a message decompresses to).
    - Also DenseText, the 128-byte padding, Padmé, safety numbers v2/v3 and key codes.
  - `store`: trust directory. It mirrors Duhcord's `Directory`: people, trust accepted/pending/rejected, our own
    devices, consent, which DMs are in Private, and verification hashes.
    - The private key lives in the OS key store through the `keyring` crate.
    - The directory is a file encrypted with a key held in the key store.
    - Where a TPM (Windows) or Secure Enclave (macOS) exists, a hardware-bound P-256 key wraps the stored X25519 key.
      Neither chip can hold an X25519 key itself, so the key is in memory only while the companion runs.
  - `bridge`: loopback WebSocket server, pairing, schema validation.
  - `app`: Tauri v2 shell (tray icon, Private windows, settings, pairing prompts). The UI is TypeScript in `ui/` and
    is shared by window and frame mode.
    - Tauri renders with the system webview (WebView2 / WKWebView / WebKitGTK), but in the companion's own process.
      Plaintext moves between UI and core over Tauri IPC, never over loopback HTTP.
- Each pinned crate version is audited before use (`cargo vet` or `cargo deny`); `Cargo.lock` is committed.

### 3.2 Bridge protocol (`spec/BRIDGE.md`)
- `ws://127.0.0.1:<port>/bridge`. The port is random and written to `~/.duhcord-companion/port`.
  The plugins read that file where the mod gives them file access (✔ BD exposes `require("fs")`; ✔ Vencord
  `native.ts` runs in the main process). Replugged plugins run in the page with no file access **(verify)**, so
  they try a small fixed port range instead.
- Each request is rejected unless:
  - `Host` is `127.0.0.1:<port>` (blocks DNS rebinding).
  - `Origin` is one of `https://discord.com`, `https://ptb.discord.com` or `https://canary.discord.com`, or there is
    none (Vencord native in main).
  - It carries the pairing token.
- Plugin → companion:
  - `hello{protocol, host, pluginVersion, userId, token}`
  - `observe{channelId, peerId, messages:[{id, authorId, content, editedAt, attachments:[{id, url, size}]}]}`
    — only messages whose last line starts with `dhc2:`, plus the DM's metadata.
  - `posted{nonce, messageId}` / `failed{nonce, reason}`
  - `history{channelId, before, messages}` (answer to `needHistory`)
  - `focus{channelId}` (the user opened a DM; the companion can bring its window or frame forward)
- Companion → plugin:
  - `send{nonce, channelId, content, files:[{bytes}]}` — `content` is always `-# encrypted messaging…\ndhc2:…`,
    files are `encrypted.bin`.
  - `edit{messageId, content}` / `delete{messageId}` (remove-image re-seal, as Duhcord does)
  - `needHistory{channelId, before}`
  - `status{channelId, mode, badge, unread}` — nothing secret. It drives the plugin's toolbar button.
- Validation: the companion refuses to emit any message whose `content` doesn't parse as a valid 0x21/0x22/0x23 frame.
  A CI test seals a canary string and checks that it never appears in bridge traffic.
- Pairing:
  - The first `hello` from a new plugin opens a companion window showing a 6-digit code. The plugin shows the same
    code, and the user clicks Allow in the companion.
  - A token is issued per mod and per Discord user ID.
  - The token isn't a secret from Discord, and doesn't need to be. It only stops other local apps and websites from
    using the bridge.

### 3.3 Private window (default)
- One window per DM, listing only private messages, with its own composer. It mirrors Duhcord's Private view: safety
  number sheet, new-key accept sheet, "Verified" state and warning lines (replayed message, unaccepted key).
- Images: v1 opens images others send. The companion fetches the `encrypted.bin` CDN URL itself, so the bytes don't
  pass through the plugin, then decrypts in memory and decodes only JPEG/PNG from trusted keys, with the same size
  caps as Duhcord.
  - Sending images, videos and reels comes in a later phase.
- Nothing decrypted is written to disk. Closing the window or locking the session clears it from memory.

### 3.4 Own devices
A companion user with two PCs has two keys. The companion has the same "This PC (main)" approval list Duhcord has,
with key codes and at most three others, but only companion keys can be approved there. To a Duhcord peer the second
PC shows up as a new key waiting to be accepted, as it does today for a new Mac.

### 3.5 Inline frame (opt-in, Settings → "Show private chats inside Discord")
- The plugin places `<iframe src="http://127.0.0.1:<port>/frame/<channelId>#<one-time ticket>">` over the message
  list and composer while the DM is in Private.
- The frame's data API only answers requests that:
  - come from the frame's own origin,
  - carry a `SameSite=Strict` cookie set by the frame page, and
  - follow a ticket redeemed exactly once.
  A page script on `discord.com` can't read the frame or call the API. The page sets
  `frame-ancestors https://discord.com https://ptb.discord.com https://canary.discord.com`.
- Anti-spoofing: the real frame shows a per-install security phrase, chosen in the companion and never sent over the
  bridge. Settings explain: "If you don't see your phrase, don't type."
- The frame API is only on while frame mode is enabled.

### 3.6 Updates and releases
- **Superseded by [`spec/UPDATES.md`](../../spec/UPDATES.md):** a signed manifest at a fixed URL, pinned hashes, its
  own key, no Tauri updater plugin. The original note follows.
- The companion updates through Tauri's updater, with Ed25519-signed manifests (same model as Duhcord's
  `UpdateVerifier`). Signing happens in a `release` GitHub Environment job that builds no third-party code, as in
  Duhcord.
- Plugins are untrusted by design, so their auto-updates (BD site, Replugged store, Vencord upstream) can't leak keys
  or plaintext. Only companion releases are security-critical.
- Builds are reproducible (`--locked`, pinned toolchain) and each release lists SHA-256 checksums.

---

## 4. The three thin plugins (shared TS `plugins/shared/bridge.ts`, no crypto)

Each plugin does the same five things:
1. Connect and pair.
2. Watch the open DM's messages, observe ciphertext, and fold each private message to one line ("🔒 Private
   message — open in Companion").
3. Add a toolbar or chat-bar button that switches the DM to Private (opens the companion window, or the frame).
4. Carry out `send` / `edit` / `delete` / `needHistory` through Discord's own message modules.
5. Show a status pill.

Plugins never put decrypted text into Discord's stores or composer, because they never have it.

| | Vencord (+ Vesktop) | Replugged | BetterDiscord |
|---|---|---|---|
| Source shape | `src/userplugins/duhcordPrivate/{index.tsx, native.ts}` — `definePlugin`, `patches`, `ChatBarButton`, `MessageEvents`, message accessories | `manifest.json` (`type: replugged-plugin`, `renderer`, optional `plaintextPatches`) ✔; `Injector`, `webpack`, `common.messages` | One `DuhcordPrivate.plugin.js` (built from TS) — `BdApi.Patcher`, `BdApi.Webpack`, `BdApi.UI`, `BdApi.Data` |
| Bridge transport | From `native.ts` in the main process ✔ (natives become `ipcMain.handle` methods); no CSP change needed for the bridge | WebSocket from the page. ✔ Replugged removes Discord's CSP entirely | WebSocket from the page. ✔ BD deletes every `content-security-policy` header |
| Frame mode | `native.ts` adds `frame-src` to `127.0.0.1:*` in Vencord's `CspPolicies` ✔ (Vencord's CSP file says plugins may extend it from `native.ts`; `127.0.0.1:*` already has `connect-src`) | Works (no CSP) | Works (no CSP) |
| What's stored | Pairing token only (`DataStore`) | Pairing token (`settings.init`) | Pairing token (`BdApi.Data`, a JSON file) |
| Not supported | Vencord Web browser extension (no `native.ts`, and a browser shouldn't reach loopback services) | — | — |

All three plugins end up the same strength, because none holds anything secret.

---

## 5. How a user installs it

### Step 1, on every client: install the companion
- **Windows:** `DuhcordCompanion-Setup.exe` (or `.msi`) from GitHub Releases; later `winget install C4BRA.DuhcordCompanion`.
  Without an Authenticode certificate, SmartScreen will warn ("More info → Run anyway").
- **macOS:** `.dmg`. Without a Developer ID it needs right-click → Open on first launch. Duhcord users on a Mac
  don't need the companion at all.
- **Linux:** AppImage plus `.deb` / `.rpm`; Flatpak later (needs loopback networking).

On first run, the companion:
1. Makes the key and shows its key code.
2. Starts in the tray and turns on start at login.
3. Opens "Connect your Discord", with one button per mod (below).

### Step 2a: BetterDiscord
1. In the companion, click **Connect → BetterDiscord**. It copies `DuhcordPrivate.plugin.js` into the BD plugins
   folder ✔ (`%APPDATA%\BetterDiscord\plugins`, `~/Library/Application Support/BetterDiscord/plugins`,
   `~/.config/BetterDiscord/plugins`). Alternatively, download it from betterdiscord.app once it's listed and drop it
   in via **Settings → Plugins → Open Plugins Folder**.
2. In Discord: **User Settings → Plugins → DuhcordPrivate → on**.
3. The plugin shows a 6-digit code, the companion shows the same one, and the user clicks **Allow**.

### Step 2b: Replugged
1. Click the install link ✔ (Replugged handles `https://replugged.dev/install?identifier=…&source=store|github` links
   in Discord). `source=github` installs from GitHub Releases and needs a `<id>.asar` plus `<id>.json` asset.
   - Or click **Connect → Replugged** in the companion, which drops `dev.c4bra.DuhcordPrivate.asar` into
     `%APPDATA%\replugged\plugins` ✔ (macOS `~/Library/Application Support/replugged/plugins`, Linux
     `~/.config/replugged/plugins`).
2. Enable it in **Settings → Replugged → Plugins**, then pair as above.

### Step 2c: Vencord / Vesktop
Vencord has no drop-in plugin loading ✔ (plugins are compiled in; `src/userplugins` is the local slot).
In order of preference:
1. **Official plugin.** If Vencord accepts it: **Settings → Vencord → Plugins → DuhcordPrivate → on**, then pair.
   Acceptance isn't up to us **(verify their submission rules first)**.
2. **Equicord** (a Vencord fork with a wider plugin catalogue), if it's accepted there **(verify)**.
3. **Userplugin build.** The companion's **Connect → Vencord** shows the steps and can run them if Git, Node and
   pnpm are present:
   ```
   git clone https://github.com/Vendicated/Vencord && cd Vencord && pnpm i
   git clone https://github.com/C4BRA/duhcord ../duhcord
   mkdir -p src/userplugins
   cp -r ../duhcord/companion/plugins/vencord/duhcordPrivate src/userplugins/
   pnpm build && pnpm inject
   ```
   - Vesktop: point Vesktop's custom Vencord location setting at that build **(verify the current option name)**.

---

## 6. Repository layout

> **Moved:** the companion now lives in `C4BRA/duhcord` under `companion/`, with the shared specs in `spec/` at the
> repository root. Companion releases are `companion-v*` pre-releases of `C4BRA/duhcord`. The original layout is
> kept below for reference.
```
spec/PROTOCOL.md        wire format (from PrivateMessaging.swift), handshake 0x23, safety number v3
spec/BRIDGE.md          bridge messages, invariants, pairing
vectors/                copied from duhcord's Tests/Vectors (CI checks they match)
companion/              Rust workspace: protocol, store, bridge, app (Tauri)
ui/                     companion UI (window + frame), TS
plugins/shared/         bridge client (TS)
plugins/vencord/duhcordPrivate/
plugins/replugged/      manifest.json + src
plugins/betterdiscord/  src → dist/DuhcordPrivate.plugin.js
.github/workflows/      ci (Rust + TS + interop on macOS), release (isolated signing job)
```

---

## 7. Phases (≈ 1 Devin session ≈ a week of human work)

| # | Work | Size | Done when |
|---|---|---|---|
| 0 | `spec/`; Duhcord: 0x23 parsing, setting (Off), no first-use trust for companion keys, label only weakens, safety number v3, per-DM switch, feature gating, vector emitter | 1 | `swift test` + strict-concurrency clean; Duhcord release out |
| 1 | `protocol` crate: every vector passes, both directions (Swift opens Rust-sealed messages on macOS CI) | 1 | interop CI green |
| 2 | `store` + `bridge`: key store, encrypted directory, pairing, schema validation, canary test, rebinding/Origin tests | 1 | tests green |
| 3 | Companion app: tray, Private window, accept/safety-number sheets, own-PC approval, image receive | 1–1.5 | live round trip with Duhcord (text + image) |
| 4 | BetterDiscord plugin (simplest loader, so it goes first for live testing) | 0.5 | send/receive with Duhcord through BD |
| 5 | Replugged plugin | 0.5 | same |
| 6 | Vencord plugin (+ Vesktop) and its submission | 0.5 | same; PR opened upstream |
| 7 | Inline frame mode + security phrase | 0.5–1 | frame can't be read from the Discord console (checked live) |
| 8 | Sending images/videos, then reels | 1–2 | matches Duhcord's caps and formats |
| 9 | Installers, updater, signing, winget/Homebrew | 1 | clean install on fresh Windows / macOS / Linux VMs |

Total ≈ 8–10 sessions. Phases 4–6 can run in parallel once phase 3 is done.

---

## 8. What I need from you
- **Two Discord test accounts** (one on Duhcord, one on each mod) for the live round-trip tests in phases 3–7.
- A macOS machine for Duhcord and the interop CI. Hosted macOS runners are enough for CI; live Duhcord tests use a
  macOS child session.
- Optional: a Windows code-signing certificate (otherwise SmartScreen warns); a Developer ID if the companion should
  open on macOS without warnings.

## 9. Decisions
1. Duhcord default for companion chat: **Off** (recommended) vs. "Ask".
2. Companion keys always need an explicit accept (recommended) vs. trust on first use.
3. Frame mode in the first release, or window-only first (recommended: window-only first, frame in phase 7).
4. Text + receiving images in v1 (recommended), sending media later.
5. UI toolkit: Tauri (recommended: one UI for window + frame) vs. fully native per platform (≈3× the UI work).
6. Vencord route: submit upstream first (recommended), with userplugin instructions meanwhile.
