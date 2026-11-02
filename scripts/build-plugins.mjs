// Builds the three plugins into plugins/dist and copies the drop-in ones into the app's resources.
//
//   plugins/dist/betterdiscord/DuhcordPrivate.plugin.js
//   plugins/dist/replugged/dev.c4bra.DuhcordPrivate.asar  (+ .json, for Replugged's GitHub installs)
//   plugins/dist/vencord/duhcordPrivate/                  (userplugin folder, shared code included)

import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { createPackage } from "@electron/asar";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const { version } = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const dist = join(root, "plugins", "dist");
rmSync(dist, { recursive: true, force: true });

const common = {
  bundle: true,
  platform: "browser",
  target: "chrome120",
  legalComments: "none",
  define: { __PLUGIN_VERSION__: JSON.stringify(version) },
  logLevel: "warning",
};

// BetterDiscord: a CommonJS file whose module.exports is the plugin class, with a META header.
const bdOut = join(dist, "betterdiscord", "DuhcordPrivate.plugin.js");
await build({
  ...common,
  entryPoints: [join(root, "plugins/betterdiscord/src/index.ts")],
  outfile: bdOut,
  format: "cjs",
  banner: {
    js: `/**
 * @name DuhcordPrivate
 * @author C4BRA
 * @description Chat in Duhcord's Private mode. Your key and decrypted messages stay in the Duhcord Companion app, never in Discord.
 * @version ${version}
 * @source https://github.com/C4BRA/duhcord-private-plugin
 * @website https://github.com/C4BRA/duhcord-private-plugin
 */`,
  },
  footer: { js: "module.exports = module.exports.default;" },
});

// Replugged: renderer.js + manifest.json packed as <id>.asar.
const rpId = "dev.c4bra.DuhcordPrivate";
const rpDir = join(dist, "replugged", rpId);
await build({
  ...common,
  entryPoints: [join(root, "plugins/replugged/src/index.ts")],
  outfile: join(rpDir, "renderer.js"),
  format: "esm",
});
const manifest = JSON.parse(readFileSync(join(root, "plugins/replugged/manifest.json"), "utf8"));
manifest.version = version;
writeFileSync(join(rpDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
writeFileSync(join(dist, "replugged", `${rpId}.json`), JSON.stringify(manifest, null, 2) + "\n");
await createPackage(rpDir, join(dist, "replugged", `${rpId}.asar`));

// Vencord: the userplugin folder, with the shared code copied in and import paths made
// extension-less for Vencord's TypeScript settings.
const vcDir = join(dist, "vencord", "duhcordPrivate");
mkdirSync(join(vcDir, "shared"), { recursive: true });
const fixImports = (text) =>
  text.replace(/(from\s+"\.{1,2}\/[^"]+)\.ts"/g, '$1"').replaceAll("__PLUGIN_VERSION__", JSON.stringify(version));
for (const file of ["index.ts", "native.ts"]) {
  writeFileSync(join(vcDir, file), fixImports(readFileSync(join(root, "plugins/vencord/duhcordPrivate", file), "utf8")));
}
for (const file of ["bridge.ts", "bridgeFile.ts", "plugin.ts"]) {
  writeFileSync(join(vcDir, "shared", file), fixImports(readFileSync(join(root, "plugins/shared", file), "utf8")));
}

// Bundle the drop-in plugins with the companion app ("Connect → BetterDiscord / Replugged").
const resources = join(root, "crates/app/resources/plugins");
mkdirSync(resources, { recursive: true });
copyFileSync(bdOut, join(resources, "DuhcordPrivate.plugin.js"));
copyFileSync(join(dist, "replugged", `${rpId}.asar`), join(resources, `${rpId}.asar`));

console.log(`Built plugins ${version} into plugins/dist`);
