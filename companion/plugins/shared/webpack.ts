// Finds Discord's internal modules by looking through webpack's module cache directly.
//
// Each mod has its own finder, but they differ in how deep they look: BetterDiscord's getByKeys
// only checks a module's top-level export unless asked otherwise, while Discord exports many
// things (the Flux dispatcher, for one) as named exports inside a module. This finder checks the
// top-level export, `.default` and every named export, so it finds them whatever mod is loaded.

export type Filter = (candidate: any) => boolean;

type Require = { c?: Record<string, { exports?: unknown }> };

let cachedRequire: Require | null = null;

function webpackRequire(scope: any = globalThis): Require | null {
  if (cachedRequire?.c) return cachedRequire;
  const chunkNames = Object.keys(scope).filter((key) => key.startsWith("webpackChunk"));
  // Discord's own chunk array first, then anything else webpack-shaped.
  chunkNames.sort((a, b) => Number(b === "webpackChunkdiscord_app") - Number(a === "webpackChunkdiscord_app"));
  for (const name of chunkNames) {
    const chunks = scope[name];
    if (!Array.isArray(chunks) || typeof chunks.push !== "function") continue;
    let found: Require | null = null;
    try {
      chunks.push([[Symbol("duhcord-private")], {}, (require: Require) => (found = require)]);
      chunks.pop();
    } catch {
      continue;
    }
    if (found && (found as Require).c) {
      cachedRequire = found;
      return found;
    }
  }
  return null;
}

/** Test hook: forget the cached require so a fake webpack can be installed. */
export function _resetWebpackCache(): void {
  cachedRequire = null;
}

function safeMatch(filter: Filter, candidate: unknown): boolean {
  if (candidate === null || (typeof candidate !== "object" && typeof candidate !== "function")) return false;
  if (candidate === globalThis || (typeof window !== "undefined" && candidate === window)) return false;
  try {
    return filter(candidate);
  } catch {
    return false;
  }
}

/** The first module export (top level, `.default` or any named export) that passes `filter`. */
export function findModule(filter: Filter, scope: any = globalThis): any {
  const require = webpackRequire(scope);
  if (!require?.c) return null;
  for (const id of Object.keys(require.c)) {
    const exports = require.c[id]?.exports as any;
    if (safeMatch(filter, exports)) return exports;
    if (!exports || (typeof exports !== "object" && typeof exports !== "function")) continue;
    let keys: string[];
    try {
      keys = Object.keys(exports);
    } catch {
      continue;
    }
    for (const key of keys) {
      let value: unknown;
      try {
        value = exports[key];
      } catch {
        continue;
      }
      if (safeMatch(filter, value)) return value;
    }
  }
  return null;
}

/** Has every property (own or inherited, so class instances with prototype methods match). */
export const byProps =
  (...props: string[]): Filter =>
  (candidate) =>
    props.every((prop) => candidate[prop] !== undefined);

/** Every named property is a function. */
export const byFunctions =
  (...names: string[]): Filter =>
  (candidate) =>
    names.every((name) => typeof candidate[name] === "function");
