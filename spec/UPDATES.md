# Duhcord Private Companion — updates

How the Companion and the plugins it installs stay up to date. It follows the model of Duhcord's own updater (README
"Updates", `Sources/DuhcordUpdateKit`): a signed manifest, a version that must be newer, every download pinned by size
and SHA-256, a renewed expiry, and nothing installed until the user confirms. The two products use **separate keys and
separate manifests**, so neither can ever install the other.

## 1. The manifest

One file, always at the same URL, so the Companion never needs GitHub's API or "latest release" (which belongs to
Duhcord):

    https://github.com/C4BRA/duhcord/releases/download/companion-manifest/companion-update.json
    https://github.com/C4BRA/duhcord/releases/download/companion-manifest/companion-update.json.sig

`companion-manifest` is a pre-release in this repository that only ever holds these two files. Its tag matches neither
`v*` (Duhcord releases) nor `companion-v*` (Companion builds), and like every Companion release it is never "latest":
`release-guard.yml` treats every `companion-*` release as one that must stay a pre-release.

```json
{
  "product": "duhcord-companion",
  "version": "0.2.0",
  "released": 1767225600,
  "expires": 1772409600,
  "notes": "What changed, shown in the update prompt.",
  "protocol": 3,
  "bridge": 1,
  "platforms": {
    "darwin-aarch64": { "url": "https://github.com/C4BRA/duhcord/releases/download/companion-v0.2.0/DuhcordCompanion-macOS-AppleSilicon-0.2.0.app.tar.gz", "size": 12345678, "sha256": "<hex>" },
    "darwin-x86_64":  { "url": "…/companion-v0.2.0/DuhcordCompanion-macOS-Intel-0.2.0.app.tar.gz", "size": 0, "sha256": "<hex>" },
    "windows-x86_64": { "url": "…/companion-v0.2.0/DuhcordCompanion-Setup-0.2.0.exe", "size": 0, "sha256": "<hex>" },
    "linux-x86_64":   { "url": "…/companion-v0.2.0/DuhcordCompanion-0.2.0-x86_64.AppImage", "size": 0, "sha256": "<hex>" }
  },
  "plugins": {
    "betterdiscord": { "version": "0.2.0" },
    "replugged": { "version": "0.2.0" },
    "vencord": { "version": "0.2.0" }
  }
}
```

- `protocol`: the private-messaging version this build speaks (PROTOCOL.md §3). `bridge`: the bridge version
  (BRIDGE.md).
- `plugins`: the plugin versions bundled in this build. The plugin files themselves come with the app (§4), so they
  need no URL here.
- Unknown fields are ignored, so later manifests can add some.

### Signature
`companion-update.json.sig` is the base64 Ed25519 signature of the exact bytes of `companion-update.json`, made with
the **Companion update key**:
- Its private half exists only as `COMPANION_UPDATE_KEY` in the `companion-release` GitHub environment. It is never
  Duhcord's update key (`DUHCORD_UPDATE_KEY`, `release` environment), and neither workflow may reference the other's
  key; the isolation check enforces this.
- Its public half is compiled into the Companion as a list (`trustedUpdateKeys`), so the key can be rotated: a release
  that trusts both the old and new key ships first, then manifests are signed with the new key only.
- Signing runs in a job with no npm or cargo packages: OpenSSL on the runner, as Duhcord's signing uses CryptoKit.

## 2. Checking

The Companion checks shortly after launch and then once a day. Settings → Updates turns it off; a "Check now" button is
always there. Downloads only come from `https://github.com/C4BRA/duhcord/releases/download/` (redirects only to
GitHub's release CDN, `objects.githubusercontent.com` / `release-assets.githubusercontent.com`).

A manifest is used only if **all** of these hold. Otherwise the check fails, and the Companion keeps its current version
and says why:

1. The signature verifies with one of `trustedUpdateKeys`.
2. `product` is `duhcord-companion`.
3. `version` is strictly newer than the running version (semantic versioning). No downgrades, ever.
4. The entry for this platform's `url` starts with
   `https://github.com/C4BRA/duhcord/releases/download/companion-v<version>/`, the tag of exactly this `version`.
5. `expires` is in the future. If it has passed, the Companion says it couldn't confirm it's up to date, but still offers
   a newer signed version (as Duhcord does). This limits how long a stale manifest can hide a newer release.
6. `protocol` is one this build can read. If it's higher, the prompt says this update is needed to keep chatting with
   people on the newer version.

## 3. Installing

When a valid newer version exists, the Companion shows an **Update** button: in the main window and the tray menu,
with the notes. Nothing downloads or installs until the user confirms. Then:

1. Download to a temporary file in the Companion's own folder. The size and SHA-256 must match the manifest, else it's
   deleted and nothing changes.
2. Install, per platform:
   - **macOS**: unpack the `.app.tar.gz` next to the running app, check that its bundle identifier is
     `dev.c4bra.duhcord-companion` and its version is the manifest's, then swap it in atomically and relaunch.
   - **Windows**: run the downloaded NSIS installer silently for the current user (`/S`). It replaces the app and
     relaunches it.
   - **Linux (AppImage)**: replace the AppImage file atomically (same path, executable bit kept) and relaunch.
   - **Linux (.deb / .rpm)**: the Companion can't replace a package-manager install. It shows the update with a link to
     the release instead of an Update button.
3. Keys, the trust directory and pairings are untouched: they live in the OS key store and the config folder, not in the
   app.

The Companion doesn't use Tauri's updater plugin: that signs every download at build time, which would put a signing
key inside the build jobs that run npm and cargo packages. Here only the manifest is signed, in a job that runs no
third-party code, and the manifest pins each download's hash, as Duhcord's does.

## 4. Plugins

The Companion bundles the BetterDiscord and Replugged plugins of the same release (`crates/app/resources/plugins`), and
remembers which mods it installed them into.

- **After an update**, on first launch, it compares each plugin it installed with the bundled one (BetterDiscord: the
  `@version` header; Replugged: `version` in the asar's manifest). If one is older, the same confirmed update replaces
  it, and the main window says so. It never writes into a mod's folder the user didn't connect through the Companion.
- **Any time a plugin connects**, it sends its version in `hello` (BRIDGE.md). If it's older than the bundled version,
  the Companion offers **Update plugin**: a one-click reinstall for BetterDiscord and Replugged, instructions for Vencord
  (which has to be rebuilt).
- **Plugin and Companion out of step**: the bridge `hello` carries the bridge version. If the plugin's is lower than the
  Companion accepts, the Companion answers `{"t":"error","code":"plugin-outdated"}` and the plugin shows "Update the
  Duhcord Private plugin (open Duhcord Companion)". If it's higher, `{"t":"error","code":"companion-outdated"}` and the
  plugin shows "Update Duhcord Companion". Neither side guesses.
- Plugins don't update themselves from GitHub: Replugged's GitHub updater reads a repository's latest release, which
  here is always Duhcord's.

## 5. Releasing (the workflows)

1. A `companion-v<version>` tag builds every platform: the installers, plus the update artifacts (`.app.tar.gz` for
   macOS, the NSIS installer for Windows, the AppImage for Linux). It drafts the `companion-v<version>` pre-release
   (`companion-release.yml`).
2. The user reviews the draft and publishes it, keeping "Set as a pre-release" ticked.
3. Publishing triggers the manifest job, in the `companion-release` environment with no npm or cargo packages. It
   downloads that release's four update artifacts (failing if any is missing or misnamed), hashes them, writes
   `companion-update.json`
   (expiry 60 days), signs it with `COMPANION_UPDATE_KEY`, and uploads both files to `companion-manifest`, replacing the
   previous ones. Draft files aren't downloadable, so the manifest only ever points at a published release.
4. A monthly job re-signs the current manifest with a new expiry, as Duhcord's `refresh-update-manifest.yml` does.

## 6. What this protects against

| attack | defence |
|---|---|
| A tampered or substituted download | size and SHA-256 pinned in the signed manifest |
| Serving an older, vulnerable version | the version must be strictly newer |
| Serving an old manifest to hide a fix | the expiry is renewed monthly; after it passes, the Companion says it can't confirm it's up to date |
| A manifest pointing at another product's or version's files | `product` and the `companion-v<version>` URL prefix |
| A Duhcord update installed by the Companion, or the reverse | separate keys, separate manifests, a `product` field, and the isolation check |
| A compromised npm or cargo package in the build | it can alter a build, but it never sees the signing key. The manifest job hashes the *published* files, so the user's review of the draft is the last gate. (Reproducible builds would close this further; not yet.) |
