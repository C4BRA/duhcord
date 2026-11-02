// Discord module lookup against a fake webpack cache shaped like Discord's (`npm test`).

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import { findDiscord } from "./plugin.ts";
import { _resetWebpackCache, byFunctions, byProps, findModule } from "./webpack.ts";

class Dispatcher {
  dispatch() {}
  subscribe() {}
  unsubscribe() {}
}

class Store {
  _dispatcher: Dispatcher;
  constructor(dispatcher: Dispatcher) {
    this._dispatcher = dispatcher;
  }
}

class UserStore extends Store {
  getCurrentUser() {}
  getUser() {}
}
class ChannelStore extends Store {
  getChannel() {}
  getDMFromUserId() {}
}
class SelectedChannelStore extends Store {
  getChannelId() {}
  getVoiceChannelId() {}
}
class MessageStore extends Store {
  getMessages() {}
  getMessage() {}
}

/** Installs `webpackChunkdiscord_app` with modules shaped like current Discord's. */
function installDiscord(options: { dispatcherOnStores?: boolean } = {}) {
  const dispatcher = new Dispatcher();
  const owner = options.dispatcherOnStores === false ? (undefined as unknown as Dispatcher) : dispatcher;
  const rest = { get() {}, post() {}, patch() {}, put() {}, del() {} };
  const cache: Record<string, { exports: unknown }> = {
    1: { exports: { Z: new UserStore(owner) } }, // stores: default-ish named export
    2: { exports: { ZP: new ChannelStore(owner), other: 1 } },
    3: { exports: new SelectedChannelStore(owner) }, // top-level export
    4: { exports: { default: new MessageStore(owner) } },
    5: { exports: { h: dispatcher, Wb: "unrelated" } }, // dispatcher: named export inside a module
    6: { exports: { tn: rest, K0: () => "https://discord.com/api/v9" } }, // REST client: named export
    7: { exports: "a string module" },
    8: {
      exports: new Proxy({}, { ownKeys: () => { throw new Error("hostile"); } }),
    },
  };
  (globalThis as any).webpackChunkdiscord_app = Object.assign([], {
    push(chunk: [unknown, unknown, (require: unknown) => void]) {
      chunk[2]({ c: cache });
      return 1;
    },
  });
  _resetWebpackCache();
  return { dispatcher, rest };
}

afterEach(() => {
  delete (globalThis as any).webpackChunkdiscord_app;
  _resetWebpackCache();
});

test("findModule looks inside named exports and handles class instances", () => {
  const { dispatcher, rest } = installDiscord();
  assert.equal(findModule(byFunctions("dispatch", "subscribe", "unsubscribe")), dispatcher);
  assert.equal(findModule(byFunctions("get", "post", "patch", "del")), rest);
  assert.equal(findModule(byProps("getChannelId", "getVoiceChannelId"))?.constructor, SelectedChannelStore);
  assert.equal(findModule(byProps("nothingHasThis")), null);
});

test("findDiscord falls back when the mod's finder only checks top-level exports (the BetterDiscord failure)", () => {
  const { dispatcher, rest } = installDiscord({ dispatcherOnStores: false });
  // Like BdApi.Webpack.getByKeys without searchExports: sees only module.exports itself.
  const topLevelOnly = (...props: string[]) => {
    const cache = { 3: new SelectedChannelStore(new Dispatcher()) };
    return Object.values(cache).find((m: any) => props.every((p) => m[p] !== undefined)) ?? null;
  };
  const discord = findDiscord(topLevelOnly);
  assert.equal(discord.Dispatcher, dispatcher);
  assert.equal(discord.RestAPI, rest);
  assert.equal(discord.UserStore.constructor, UserStore);
  assert.equal(discord.MessageStore.constructor, MessageStore);
});

test("findDiscord prefers the dispatcher the stores use, and works with no mod finder at all", () => {
  const { dispatcher } = installDiscord();
  assert.equal(findDiscord(undefined).Dispatcher, dispatcher);
});

test("findDiscord ignores a wrong result from the mod's finder and names everything missing", () => {
  installDiscord();
  const wrong = () => ({ getAPIBaseURL() {}, get() {}, post() {} }); // no patch/del, not a store
  assert.ok(findDiscord(wrong).RestAPI.del);

  (globalThis as any).webpackChunkdiscord_app = Object.assign([], {
    push(chunk: [unknown, unknown, (require: unknown) => void]) {
      chunk[2]({ c: {} });
      return 1;
    },
  });
  _resetWebpackCache();
  assert.throws(() => findDiscord(undefined), /UserStore, ChannelStore, SelectedChannelStore, MessageStore, Dispatcher, RestAPI/);
});
