# Duhcord Private Companion + plugins

Chat in [Duhcord](https://github.com/C4BRA/duhcord)'s Private mode from Vencord / Vesktop, Replugged and BetterDiscord.

- **The companion** is a small native app. It holds your key in the OS key store (Keychain, Credential Manager or
  Secret Service), seals and opens messages, and shows private chats in its own windows.
- **The plugins** are thin. They pass ciphertext between Discord and the companion over a loopback WebSocket. They
  never hold a key and never see plaintext, so a compromised plugin or Discord's own code can at most drop, delay or
  replay messages.

See [`docs/PLAN.md`](docs/PLAN.md) for the design. The wire format is in [`spec/PROTOCOL.md`](spec/PROTOCOL.md), the
bridge in [`spec/BRIDGE.md`](spec/BRIDGE.md), and the cross-implementation test vectors in
[`spec/VECTORS.md`](spec/VECTORS.md).

## Layout

| Path | What |
|---|---|
| `crates/protocol` | Wire format, byte-compatible with Duhcord's `PrivateMessaging.swift` (seal/open, files, handshakes, safety numbers) |
| `crates/interop` | `duhcord-interop gen|check`: writes the Rust vectors and checks Duhcord's Swift ones |
| `crates/engine` | Per-account trust state machine: peer keys, own Macs, consent, replay warnings, message views |
| `crates/store` | OS key store + encrypted trust directory + hashed pairing tokens; fails closed |
| `crates/bridge` | Loopback WebSocket server for the plugins: Origin/Host allowlist, limits, 6-digit pairing |
| `crates/service` | Headless core: routes bridge traffic through the engine, saves the directory, fetches images, UI API |
| `crates/app` | Tauri v2 shell: tray, main window, one window per private chat, plugin installers |
| `ui/` | The companion's UI (plain HTML/CSS/JS, no build step) |
| `plugins/shared` | Bridge client and Discord glue shared by all three plugins |
| `plugins/betterdiscord`, `plugins/replugged`, `plugins/vencord` | Per-mod entry points |
| `scripts/build-plugins.mjs` | Builds the plugins into `plugins/dist` and bundles the drop-in ones with the app |

## Develop

Requirements: Rust (pinned by `rust-toolchain.toml`), Node 22. On Linux:
`libdbus-1-dev pkg-config libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev`.

```bash
npm ci
npm run build          # plugins → plugins/dist (and the app's bundled copies)
npm test               # plugin unit tests + interop with the real Rust bridge
cargo test --workspace # protocol, engine, store, bridge, service
npm run app:dev        # run the companion
```

## Release

Push a `v*` tag (or run the **Release** workflow by hand). It builds the companion for macOS Apple Silicon, macOS
Intel, Windows x64 and Linux x64, plus the three plugins. It then drafts a GitHub release with one-click zips, native
installers and `SHA256SUMS.txt`. Nothing is code-signed yet, and the Tauri updater isn't wired up yet (it needs a
signing key in a protected `release` environment, see `docs/PLAN.md` §3.6).

## Status

- **Done:** protocol + interop vectors, engine, store, bridge, service, companion app, the three plugins, CI and the
  release workflow.
- **Not yet tested live:** a round trip with Duhcord through a real Discord client on each mod (plan phases 3–6),
  and the Vencord upstream submission. The Discord-side glue (`plugins/shared/plugin.ts`) relies on Discord's
  internal stores and REST client, found by property names. Expect to adjust those lookups after the first live
  test.
- **Later phases:** inline frame mode, sending media, the updater and signing.
