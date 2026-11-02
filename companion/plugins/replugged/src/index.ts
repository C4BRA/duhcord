// Replugged: renderer.js inside dev.c4bra.DuhcordPrivate.asar (see scripts/build-plugins.mjs).
// Replugged plugins run in the page with no file access, so the bridge tries 47823…47827.
import { DuhcordPrivatePlugin } from "../../shared/plugin.ts";

declare const replugged: any;

const ID = "dev.c4bra.DuhcordPrivate";
let plugin: DuhcordPrivatePlugin | null = null;

export async function start(): Promise<void> {
  const settings = await Promise.resolve(replugged.settings.init(ID));
  const logger = replugged.Logger?.plugin?.("DuhcordPrivate");
  const tokens = (): Record<string, string> => settings.get("tokens", {}) ?? {};
  plugin = new DuhcordPrivatePlugin({
    host: "replugged",
    pluginVersion: __PLUGIN_VERSION__,
    findByProps: (...props) => replugged.webpack.getByProps(...props),
    loadToken: (userId) => tokens()[userId] ?? null,
    saveToken: (userId, token) => {
      const all = { ...tokens() };
      if (token) all[userId] = token;
      else delete all[userId];
      settings.set("tokens", all);
    },
    log: (...args) => (logger ? logger.warn(...args) : console.warn("[DuhcordPrivate]", ...args)),
  });
  plugin.start();
}

export function stop(): void {
  plugin?.stop();
  plugin = null;
}
