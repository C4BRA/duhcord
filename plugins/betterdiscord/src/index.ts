// BetterDiscord: one DuhcordPrivate.plugin.js, built from this file (see scripts/build-plugins.mjs).
import { bridgeFilePath, parseBridgeFile } from "../../shared/bridgeFile.ts";
import { DuhcordPrivatePlugin } from "../../shared/plugin.ts";

declare const BdApi: any;
declare const require: (id: string) => any;
declare const process: { platform: string; env: Record<string, string | undefined> };

const NAME = "DuhcordPrivate";

function readBridgePort(): number | null {
  try {
    const fs = require("fs");
    const path = require("path");
    const home = process.env.HOME ?? process.env.USERPROFILE ?? "";
    const file = bridgeFilePath({ platform: process.platform, env: process.env, home, join: path.join });
    return parseBridgeFile(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

export default class DuhcordPrivate {
  private plugin: DuhcordPrivatePlugin | null = null;

  start(): void {
    const tokens = (): Record<string, string> => BdApi.Data.load(NAME, "tokens") ?? {};
    this.plugin = new DuhcordPrivatePlugin({
      host: "betterdiscord",
      pluginVersion: __PLUGIN_VERSION__,
      findByProps: (...props) => BdApi.Webpack.getByKeys(...props),
      loadToken: (userId) => tokens()[userId] ?? null,
      saveToken: (userId, token) => {
        const all = tokens();
        if (token) all[userId] = token;
        else delete all[userId];
        BdApi.Data.save(NAME, "tokens", all);
      },
      bridgePort: readBridgePort,
      log: (...args) => console.warn(`[${NAME}]`, ...args),
    });
    try {
      this.plugin.start();
    } catch (error) {
      this.plugin = null;
      BdApi.UI.showToast(`Duhcord Private couldn't start: ${String(error)}`, { type: "error" });
    }
  }

  stop(): void {
    this.plugin?.stop();
    this.plugin = null;
  }
}
