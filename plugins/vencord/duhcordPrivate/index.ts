/*
 * Duhcord Private for Vencord / Vesktop.
 * Copy this folder (from the release zip, which includes ./shared) into Vencord's src/userplugins.
 */

import * as DataStore from "@api/DataStore";
import definePlugin, { type PluginNative } from "@utils/types";
import { findByProps } from "@webpack";

import { DuhcordPrivatePlugin } from "./shared/plugin";

const Native = VencordNative.pluginHelpers.DuhcordPrivate as PluginNative<typeof import("./native")>;
const TOKENS = "DuhcordPrivate_tokens";

let instance: DuhcordPrivatePlugin | null = null;

export default definePlugin({
    name: "DuhcordPrivate",
    description: "Chat in Duhcord's Private mode. Your key and decrypted messages stay in the Duhcord Companion app, never in Discord.",
    authors: [{ name: "C4BRA", id: 0n }],

    start() {
        instance = new DuhcordPrivatePlugin({
            host: typeof IS_VESKTOP !== "undefined" && IS_VESKTOP ? "vesktop" : "vencord",
            pluginVersion: __PLUGIN_VERSION__,
            findByProps: (...props: string[]) => findByProps(...props),
            loadToken: async (userId: string) => ((await DataStore.get<Record<string, string>>(TOKENS)) ?? {})[userId] ?? null,
            saveToken: async (userId: string, token: string | null) => {
                await DataStore.update<Record<string, string>>(TOKENS, (all = {}) => {
                    if (token) all[userId] = token;
                    else delete all[userId];
                    return all;
                });
            },
            bridgePort: () => Native.readBridgePort().catch(() => null),
            log: (...args: unknown[]) => console.warn("[DuhcordPrivate]", ...args),
        });
        instance.start();
    },

    stop() {
        instance?.stop();
        instance = null;
    },
});
