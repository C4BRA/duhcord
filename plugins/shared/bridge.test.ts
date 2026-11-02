// Run with `npm test` (node:test, no browser). The last test drives the client against the real
// Rust bridge (crates/bridge/examples/plugin_test_server.rs).

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { WebSocket } from "ws";

import { type Adapter, DuhcordBridge, isPrivateContent, type SocketLike, type Status, type WireMessage } from "./bridge.ts";
import { bridgeFilePath, parseBridgeFile } from "./bridgeFile.ts";
import { toWire } from "./plugin.ts";

const PRIVATE = "-# encrypted messaging by C4BRA/duhcord 🤫\ndhc2:㐀㐁㐂";
const ME = "111111111111111111";
const PEER = "222222222222222222";
const CHANNEL = "333333333333333333";

class FakeSocket implements SocketLike {
  readyState = 0;
  sent: any[] = [];
  onopen: ((event: unknown) => void) | null = null;
  onclose: ((event: unknown) => void) | null = null;
  onerror: ((event: unknown) => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  readonly url: string;
  constructor(url: string) {
    this.url = url;
  }
  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
  }
  open() {
    this.readyState = 1;
    this.onopen?.({});
  }
  receive(frame: unknown) {
    this.onmessage?.({ data: JSON.stringify(frame) });
  }
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

function message(id: string, content: string, author = PEER): WireMessage {
  return { id, authorId: author, content, editedAt: null, attachments: [] };
}

function fakeAdapter(overrides: Partial<Adapter> = {}) {
  const sockets: FakeSocket[] = [];
  const posted: Array<[string, string]> = [];
  const tokens = new Map<string, string | null>();
  const pairing: Array<string | null> = [];
  const statuses: Status[] = [];
  const adapter: Adapter = {
    host: "betterdiscord",
    pluginVersion: "test",
    ports: () => [47825],
    openSocket: (url) => {
      const socket = new FakeSocket(url);
      sockets.push(socket);
      return socket;
    },
    loadToken: (userId) => tokens.get(userId) ?? null,
    saveToken: (userId, token) => void tokens.set(userId, token),
    sendMessage: async (channelId, content) => {
      posted.push([channelId, content]);
      return "444444444444444444";
    },
    editMessage: async () => {},
    deleteMessage: async () => {},
    loadHistory: async () => ({ messages: [], exhausted: true }),
    onPairing: (code) => void pairing.push(code),
    onStatus: (status) => void statuses.push(status),
    ...overrides,
  };
  return { adapter, sockets, posted, tokens, pairing, statuses };
}

async function readyBridge(overrides: Partial<Adapter> = {}) {
  const fake = fakeAdapter(overrides);
  const bridge = new DuhcordBridge(fake.adapter);
  bridge.start(ME);
  await tick();
  const socket = fake.sockets[0];
  socket.open();
  await tick();
  socket.receive({ t: "ready", userId: ME, companion: "1.0.0" });
  bridge.reportDm({ channelId: CHANNEL, peer: { id: PEER, username: "peer" }, me: { id: ME, username: "me" } });
  socket.sent.length = 0;
  return { ...fake, bridge, socket };
}

test("private content is recognised only by its last line", () => {
  assert.ok(isPrivateContent(PRIVATE));
  assert.ok(isPrivateContent("dhc2:㐀"));
  assert.ok(!isPrivateContent("dhc2:"));
  assert.ok(!isPrivateContent("dhc2:㐀\nhello"));
  assert.ok(!isPrivateContent("hello dhc2:㐀"));
  assert.ok(!isPrivateContent("x".repeat(1995) + "\ndhc2:㐀"));
  assert.ok(!isPrivateContent(42));
});

test("hello carries the stored token; pairing shows the code and stores the token", async () => {
  const fake = fakeAdapter();
  fake.tokens.set(ME, "stored-token");
  const bridge = new DuhcordBridge(fake.adapter);
  bridge.start(ME);
  await tick();
  const socket = fake.sockets[0];
  assert.equal(socket.url, "ws://127.0.0.1:47825/bridge");
  socket.open();
  await tick();
  assert.deepEqual(socket.sent[0], { t: "hello", v: 1, host: "betterdiscord", plugin: "test", userId: ME, token: "stored-token" });

  socket.receive({ t: "pairing", code: "123456" });
  socket.receive({ t: "paired", token: "new-token" });
  await tick();
  assert.equal(fake.tokens.get(ME), "new-token");
  socket.receive({ t: "ready", userId: ME, companion: "1.0.0" });
  await tick();
  assert.deepEqual(fake.pairing, ["123456", null]);
  assert.ok(bridge.isReady);
  bridge.stop();
});

test("only ciphertext is posted; plain content is refused with not-private", async () => {
  const { socket, posted, bridge } = await readyBridge();
  socket.receive({ t: "send", nonce: "a", channelId: CHANNEL, content: "hello in plain text" });
  socket.receive({ t: "send", nonce: "b", channelId: CHANNEL, content: PRIVATE });
  socket.receive({ t: "send", nonce: "c", channelId: "999999999999999999", content: PRIVATE });
  socket.receive({ t: "edit", nonce: "d", channelId: CHANNEL, messageId: "555555555555555555", content: "plain" });
  await tick();
  assert.deepEqual(posted, [[CHANNEL, PRIVATE]]);
  assert.deepEqual(socket.sent, [
    { t: "sendFailed", nonce: "a", error: "not-private" },
    { t: "sendFailed", nonce: "c", error: "unknown-channel" },
    { t: "sendFailed", nonce: "d", error: "not-private" },
    { t: "sent", nonce: "b", messageId: "444444444444444444" },
  ]);
  bridge.stop();
});

test("a failed post is reported with the HTTP status", async () => {
  const { socket, bridge } = await readyBridge({
    sendMessage: async () => {
      throw Object.assign(new Error("nope"), { status: 403 });
    },
  });
  socket.receive({ t: "send", nonce: "x", channelId: CHANNEL, content: PRIVATE });
  await tick();
  assert.deepEqual(socket.sent, [{ t: "sendFailed", nonce: "x", error: "http-403" }]);
  bridge.stop();
});

test("reported messages are filtered to private ones and sorted oldest first", async () => {
  const { socket, bridge } = await readyBridge();
  bridge.reportMessages(CHANNEL, [message("30", PRIVATE), message("100", "plain"), message("9", PRIVATE)], "9", false);
  bridge.reportMessages("777777777777777777", [message("1", PRIVATE)], null, false); // unknown DM
  assert.equal(socket.sent.length, 1);
  assert.deepEqual(
    socket.sent[0].messages.map((m: WireMessage) => m.id),
    ["9", "30"],
  );
  assert.equal(socket.sent[0].before, "9");
  bridge.stop();
});

test("needHistory answers with private messages and the oldest id as the next cursor", async () => {
  const { socket, bridge } = await readyBridge({
    loadHistory: async (_channel, before) => {
      assert.equal(before, "500");
      return { messages: [message("450", PRIVATE), message("420", "plain"), message("480", "plain")], exhausted: false };
    },
  });
  socket.receive({ t: "needHistory", channelId: CHANNEL, before: "500" });
  await tick();
  assert.equal(socket.sent.length, 1);
  assert.equal(socket.sent[0].t, "messages");
  assert.deepEqual(socket.sent[0].messages.map((m: WireMessage) => m.id), ["450"]);
  assert.equal(socket.sent[0].before, "420");
  assert.equal(socket.sent[0].exhausted, false);
  bridge.stop();
});

test("status frames are validated and kept per channel", async () => {
  const { socket, statuses, bridge } = await readyBridge();
  socket.receive({ t: "status", channelId: CHANNEL, state: "ready", verified: true, newKey: false, peerClass: "duhcord" });
  socket.receive({ t: "status", channelId: CHANNEL, state: "pwned", verified: true });
  await tick();
  assert.equal(statuses.length, 1);
  assert.equal(bridge.status(CHANNEL)?.state, "ready");
  assert.equal(bridge.status(CHANNEL)?.verified, true);
  bridge.stop();
});

test("denied pairing forgets the token and stops", async () => {
  const fake = fakeAdapter();
  fake.tokens.set(ME, "old");
  const bridge = new DuhcordBridge(fake.adapter);
  bridge.start(ME);
  await tick();
  fake.sockets[0].open();
  await tick();
  fake.sockets[0].receive({ t: "error", code: "denied" });
  await tick();
  assert.equal(fake.tokens.get(ME), null);
  assert.equal(bridge._socket, null);
});

test("toWire accepts raw API messages and store records", () => {
  assert.deepEqual(
    toWire({
      id: "1",
      author: { id: "2" },
      content: PRIVATE,
      edited_timestamp: "2026-11-02T10:00:00.000+00:00",
      attachments: [{ id: "9", filename: "encrypted.bin", size: 145, url: "https://cdn.discordapp.com/x" }],
    }),
    {
      id: "1",
      authorId: "2",
      content: PRIVATE,
      editedAt: "2026-11-02T10:00:00.000Z",
      attachments: [{ id: "9", filename: "encrypted.bin", size: 145, url: "https://cdn.discordapp.com/x" }],
    },
  );
  assert.equal(toWire({ id: "1", author: { id: "2" }, content: "x", editedTimestamp: { toDate: () => new Date(0) } })?.editedAt, "1970-01-01T00:00:00.000Z");
  assert.equal(toWire({ id: "nope", author: { id: "2" }, content: "x" }), null);
});

test("bridge.json location and parsing follow spec/BRIDGE.md", () => {
  const join = (...parts: string[]) => parts.join("/");
  assert.equal(bridgeFilePath({ platform: "win32", env: { APPDATA: "C:/Users/a/AppData/Roaming" }, home: "C:/Users/a", join }), "C:/Users/a/AppData/Roaming/DuhcordCompanion/bridge.json");
  assert.equal(bridgeFilePath({ platform: "darwin", env: {}, home: "/Users/a", join }), "/Users/a/Library/Application Support/DuhcordCompanion/bridge.json");
  assert.equal(bridgeFilePath({ platform: "linux", env: {}, home: "/home/a", join }), "/home/a/.config/DuhcordCompanion/bridge.json");
  assert.equal(bridgeFilePath({ platform: "linux", env: { XDG_CONFIG_HOME: "/x" }, home: "/home/a", join }), "/x/DuhcordCompanion/bridge.json");
  assert.equal(parseBridgeFile('{"port":47824,"version":1}'), 47824);
  assert.equal(parseBridgeFile('{"port":80,"version":1}'), null);
  assert.equal(parseBridgeFile("garbage"), null);
});

test("interop with the real Rust bridge", { timeout: 600_000 }, async (t) => {
  const root = join(import.meta.dirname, "..", "..");
  const built = spawnSync("cargo", ["build", "-q", "-p", "duhcord-companion-bridge", "--example", "plugin_test_server"], {
    cwd: root,
    stdio: "inherit",
  });
  if (built.error || built.status !== 0) {
    if (process.env.CI) assert.fail("could not build the bridge test server");
    t.skip("cargo isn't available");
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), "duhcord-plugin-interop-"));
  const server = spawn(join(root, "target", "debug", "examples", "plugin_test_server"), [dir], { stdio: ["ignore", "pipe", "inherit"] });
  t.after(() => {
    server.kill();
    rmSync(dir, { recursive: true, force: true });
  });
  const lines = createInterface({ input: server.stdout! });
  const events: any[] = [];
  const waiters: Array<() => void> = [];
  lines.on("line", (line) => {
    events.push(JSON.parse(line));
    waiters.splice(0).forEach((wake) => wake());
  });
  const next = async (name: string) => {
    for (;;) {
      const index = events.findIndex((event) => event.event === name);
      if (index >= 0) return events.splice(index, 1)[0];
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`timed out waiting for ${name}`)), 10_000);
        waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  };

  const listening = await next("listening");
  const fake = fakeAdapter({
    ports: () => [listening.port],
    // Node's WebSocket client sends no Origin, like Vencord's main process.
    openSocket: (url) => new WebSocket(url) as unknown as SocketLike,
    loadHistory: async () => ({ messages: [message("950", PRIVATE), message("900", "plain")], exhausted: true }),
  });
  const bridge = new DuhcordBridge(fake.adapter);
  t.after(() => bridge.stop());
  bridge.start(ME);

  const pairing = await next("pairing");
  assert.equal(pairing.host, "betterdiscord");
  assert.equal(pairing.userId, ME);
  await next("ready");
  while (!bridge.isReady) await tick(); // the server logs "ready" before the plugin reads it
  assert.deepEqual(fake.pairing, [pairing.code, null]);
  assert.equal(fake.tokens.get(ME)?.length, 43);

  bridge.reportDm({ channelId: CHANNEL, peer: { id: PEER, username: "peer" }, me: { id: ME, username: "me" } });
  assert.equal((await next("dm")).peer, "peer");
  const sent = await next("sent");
  assert.deepEqual(sent, { event: "sent", nonce: "n1", messageId: "444444444444444444" });
  assert.equal(fake.posted.length, 1);
  assert.ok(isPrivateContent(fake.posted[0][1]));
  assert.equal(fake.statuses[0]?.state, "waiting");

  bridge.reportMessages(CHANNEL, [message("1000", PRIVATE, ME)], null, false);
  assert.deepEqual((await next("messages")).ids, ["1000"]);
  const history = await next("messages");
  assert.deepEqual(history.ids, ["950"]);
  assert.equal(history.before, "900");
  assert.equal(history.exhausted, true);

  // Reconnecting reuses the stored token: no second pairing.
  bridge.stop();
  await next("disconnected");
  bridge.start(ME);
  await next("ready");
  while (!bridge.isReady) await tick();
  assert.equal(events.filter((event) => event.event === "pairing").length, 0);
});
