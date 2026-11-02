/*
 * Runs in Discord's main process (Vencord natives become ipcMain handlers). It only reads the port
 * the companion wrote; it never touches keys or messages.
 */

import type { IpcMainInvokeEvent } from "electron";
import { readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

import { bridgeFilePath, parseBridgeFile } from "./shared/bridgeFile";

// Vencord passes the IPC event first; the renderer calls Native.readBridgePort() with no arguments.
export function readBridgePort(_event: IpcMainInvokeEvent): number | null {
    try {
        const file = bridgeFilePath({ platform: process.platform, env: process.env, home: homedir(), join });
        return parseBridgeFile(readFileSync(file, "utf8"));
    } catch {
        return null;
    }
}
