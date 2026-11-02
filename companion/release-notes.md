> This is a **Duhcord Companion** release, for Vencord / Replugged / BetterDiscord users. It isn't a Duhcord
> update; Duhcord itself updates from its own releases.

## Install

**1. The companion** (holds your key; Discord never sees it or your decrypted messages)

| Platform | One-click | Other formats |
|---|---|---|
| macOS (Apple Silicon) | `DuhcordCompanion-macOS-AppleSilicon-*.zip` | `.dmg` |
| macOS (Intel) | `DuhcordCompanion-macOS-Intel-*.zip` | `.dmg` |
| Windows x64 | `DuhcordCompanion-Windows-x64-*.zip` (installer inside) | `DuhcordCompanion-Setup-*.exe`, `.msi` |
| Linux x64 | `DuhcordCompanion-Linux-x64-*.zip` (AppImage inside) | `.AppImage`, `.deb`, `.rpm` |

The builds aren't code-signed yet: on macOS right-click → Open the first time; on Windows SmartScreen asks
"More info → Run anyway".

**2. The plugin for your Discord mod** (it only passes ciphertext)

- **BetterDiscord:** in the companion click *Connect → BetterDiscord*, or unzip `DuhcordPrivate-BetterDiscord-*.zip`
  into your plugins folder. Then User Settings → Plugins → DuhcordPrivate → on.
- **Replugged:** in the companion click *Connect → Replugged*, or put `dev.c4bra.DuhcordPrivate.asar` in your
  Replugged plugins folder. Then Settings → Replugged → Plugins → Duhcord Private → on.
- **Vencord / Vesktop:** unzip `DuhcordPrivate-Vencord-*.zip` into Vencord's `src/userplugins/` (create that folder if it's missing)
  so you get `src/userplugins/duhcordPrivate/`, then
  `pnpm build && pnpm inject`.

**3. Pair:** Discord shows a 6-digit code, the companion shows the same code: click **Allow**.

Check downloads against `SHA256SUMS.txt`.
