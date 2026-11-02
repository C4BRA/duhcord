The release workflow puts the built plugins here before bundling the app:

- `DuhcordPrivate.plugin.js` (BetterDiscord)
- `dev.c4bra.DuhcordPrivate.asar` (Replugged)

**Connect → BetterDiscord / Replugged** in the companion copies them into the mod's plugins folder.
Run `npm run build` at the repository root to produce them for a local build.
