// Where the companion writes `bridge.json` (spec/BRIDGE.md), for mods that can read files.

export interface PathEnv {
  platform: string;
  env: Record<string, string | undefined>;
  home: string;
  join(...parts: string[]): string;
}

export function bridgeFilePath({ platform, env, home, join }: PathEnv): string {
  if (platform === "win32") return join(env.APPDATA ?? join(home, "AppData", "Roaming"), "DuhcordCompanion", "bridge.json");
  if (platform === "darwin") return join(home, "Library", "Application Support", "DuhcordCompanion", "bridge.json");
  return join(env.XDG_CONFIG_HOME || join(home, ".config"), "DuhcordCompanion", "bridge.json");
}

export function parseBridgeFile(text: string): number | null {
  try {
    const value = JSON.parse(text);
    return value && value.version === 1 && Number.isInteger(value.port) && value.port >= 47823 && value.port <= 47827
      ? value.port
      : null;
  } catch {
    return null;
  }
}
