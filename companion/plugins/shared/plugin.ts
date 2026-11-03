// The whole plugin, minus how each mod finds Discord's modules and stores the pairing token.
//
// It watches 1:1 DMs, reports private messages to the companion, posts what the companion asks
// through Discord's own REST client, folds ciphertext into a one-line "🔒 Private message", and
// shows a "🔒 Private" pill for the open DM. It never holds a key or plaintext.

import {
  type Adapter,
  DEFAULT_PORTS,
  type Dm,
  DuhcordBridge,
  type History,
  type Host,
  isPrivateContent,
  isSnowflake,
  type SocketLike,
  type Status,
  type WireMessage,
} from "./bridge.ts";
import { byFunctions, type Filter, findModule } from "./webpack.ts";

export type FindByProps = (...props: string[]) => any;

export interface PluginOptions {
  host: Host;
  pluginVersion: string;
  /** The mod's module finder. Optional: the plugin falls back to its own search. */
  findByProps?: FindByProps;
  loadToken(userId: string): Promise<string | null> | string | null;
  saveToken(userId: string, token: string | null): Promise<void> | void;
  /** Port from `bridge.json`, where the mod can read files. */
  bridgePort?(): Promise<number | null> | number | null;
  openSocket?(url: string): SocketLike;
  log?(...args: unknown[]): void;
}

interface Discord {
  UserStore: any;
  ChannelStore: any;
  SelectedChannelStore: any;
  MessageStore: any;
  Dispatcher: any;
  RestAPI: any;
}

const DM_CHANNEL = 1;
const HISTORY_PAGE = 100;
const STYLE_ID = "duhcord-private-style";
const PILL_ID = "duhcord-private-pill";
const FOLDED = "duhcord-private-folded";

const CSS = `
.${FOLDED} > * { display: none !important; }
.${FOLDED} { cursor: pointer; }
.${FOLDED}::after {
  content: "🔒 Private message · open in Duhcord Companion";
  color: var(--text-muted, #949ba4);
  font-style: italic;
}
#${PILL_ID} {
  position: fixed; right: 28px; bottom: 92px; z-index: 1000;
  display: none; align-items: center; gap: 6px;
  padding: 6px 12px; border-radius: 999px; border: 0; cursor: pointer;
  font: 500 13px/1.3 var(--font-primary, system-ui, sans-serif);
  color: var(--white, #fff); background: var(--brand-500, #5865f2);
  box-shadow: 0 2px 10px rgb(0 0 0 / .3);
}
#${PILL_ID}[data-tone="muted"] { background: var(--background-modifier-accent, #4e5058); }
#${PILL_ID}[data-tone="warn"] { background: var(--status-warning, #f0b232); color: #000; }
#${PILL_ID}[data-tone="ok"] { background: var(--status-positive, #23a55a); }
`;

export function findDiscord(findByProps: FindByProps | undefined): Discord {
  const missing: string[] = [];
  // The mod's own finder first (if its result really has what we need), then a deep search of
  // webpack's cache, which also looks inside each module's named exports.
  const find = (label: string, filter: Filter, ...props: string[]) => {
    let module: any = null;
    try {
      module = findByProps?.(...props) ?? null;
    } catch {
      module = null;
    }
    if (!module || !safeTest(filter, module)) module = findModule(filter);
    if (!module) missing.push(label);
    return module;
  };
  const UserStore = find("UserStore", byFunctions("getCurrentUser", "getUser"), "getCurrentUser", "getUser");
  const ChannelStore = find("ChannelStore", byFunctions("getChannel", "getDMFromUserId"), "getChannel", "getDMFromUserId");
  const SelectedChannelStore = find(
    "SelectedChannelStore",
    byFunctions("getChannelId", "getVoiceChannelId"),
    "getChannelId",
    "getVoiceChannelId",
  );
  const MessageStore = find("MessageStore", byFunctions("getMessages", "getMessage"), "getMessages", "getMessage");
  // Every Flux store keeps a reference to the dispatcher, which is the most reliable route to it.
  const isDispatcher = byFunctions("dispatch", "subscribe", "unsubscribe");
  const storeDispatcher = [UserStore, ChannelStore, MessageStore]
    .map((store) => store?._dispatcher)
    .find((candidate) => safeTest(isDispatcher, candidate));
  const Dispatcher = storeDispatcher ?? find("Dispatcher", isDispatcher, "dispatch", "subscribe", "unsubscribe");
  // Discord's REST client has get/post/put/patch/del; other modules share some of those names, so
  // ask for all five and prefer the one that also knows Discord's API base URL.
  const RestAPI =
    findModule(byFunctions("getAPIBaseURL", "get", "post", "put", "patch", "del")) ??
    find("RestAPI", byFunctions("get", "post", "put", "patch", "del"), "get", "post", "put", "patch", "del");
  if (missing.length) {
    throw new Error(`Duhcord Private: couldn't find Discord's ${missing.join(", ")}. Discord may have changed; please report this.`);
  }
  return { UserStore, ChannelStore, SelectedChannelStore, MessageStore, Dispatcher, RestAPI };
}

function safeTest(filter: Filter, candidate: unknown): boolean {
  if (candidate === null || (typeof candidate !== "object" && typeof candidate !== "function")) return false;
  try {
    return filter(candidate);
  } catch {
    return false;
  }
}

function toIso(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  const date = typeof value === "object" && value && "toDate" in value ? (value as any).toDate() : new Date(value as any);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

const ECHO_TIMEOUT_MS = 8000;

/** The new message's ID from a REST reply, whichever shape Discord's client returns. */
export function messageIdFrom(response: any): string | null {
  let body = response?.body ?? response?.data ?? response;
  if (typeof body === "string") {
    try {
      body = JSON.parse(body);
    } catch {
      return null;
    }
  }
  if (typeof response?.text === "string" && !isSnowflake(body?.id)) {
    try {
      body = JSON.parse(response.text);
    } catch {
      // keep body
    }
  }
  const id = body?.id ?? body?.message?.id;
  return isSnowflake(id) ? id : null;
}

/** Keys and types only (never values), for the console when a reply isn't understood. */
function describeShape(value: any): string {
  if (value === null || typeof value !== "object") return typeof value;
  return Object.keys(value)
    .slice(0, 20)
    .map((key) => `${key}:${value[key] === null ? "null" : typeof value[key]}`)
    .join(",");
}

/** Accepts both Discord's raw API messages and its MessageStore records. */
export function toWire(message: any): WireMessage | null {
  if (!message || !isSnowflake(message.id) || typeof message.content !== "string") return null;
  const authorId = message.author?.id;
  if (!isSnowflake(authorId)) return null;
  return {
    id: message.id,
    authorId,
    content: message.content,
    editedAt: toIso(message.edited_timestamp ?? message.editedTimestamp),
    attachments: (Array.isArray(message.attachments) ? message.attachments : [])
      .filter((a: any) => a && typeof a.id === "string" && typeof a.url === "string")
      .map((a: any) => ({ id: a.id, filename: String(a.filename ?? ""), size: Number(a.size ?? 0), url: a.url })),
  };
}

export class DuhcordPrivatePlugin {
  private discord: Discord | null = null;
  private bridge: DuhcordBridge | null = null;
  private observer: MutationObserver | null = null;
  private pill: HTMLButtonElement | null = null;
  private pairingCode: string | null = null;
  private connected = false;
  private outdated: "plugin" | "companion" | null = null;
  private readonly subscriptions: Array<[string, (event: any) => void]> = [];
  private readonly reported = new Set<string>();

  private readonly options: PluginOptions;

  constructor(options: PluginOptions) {
    this.options = options;
  }

  start(): void {
    this.outdated = null;
    this.discord = findDiscord(this.options.findByProps);
    const adapter: Adapter = {
      host: this.options.host,
      pluginVersion: this.options.pluginVersion,
      ports: async () => {
        const port = await Promise.resolve(this.options.bridgePort?.()).catch(() => null);
        return typeof port === "number" && DEFAULT_PORTS.includes(port)
          ? [port, ...DEFAULT_PORTS.filter((p) => p !== port)]
          : DEFAULT_PORTS;
      },
      openSocket: (url) => (this.options.openSocket ? this.options.openSocket(url) : (new WebSocket(url) as unknown as SocketLike)),
      loadToken: (userId) => this.options.loadToken(userId),
      saveToken: (userId, token) => this.options.saveToken(userId, token),
      sendMessage: (channelId, content) => this.post(channelId, content),
      editMessage: async (channelId, messageId, content) => {
        await this.discord!.RestAPI.patch({ url: `/channels/${channelId}/messages/${messageId}`, body: { content } });
      },
      deleteMessage: async (channelId, messageId) => {
        await this.discord!.RestAPI.del({ url: `/channels/${channelId}/messages/${messageId}` });
      },
      loadHistory: (channelId, before) => this.history(channelId, before),
      onReady: () => {
        this.reported.clear();
        this.reportSelected();
      },
      onPairing: (code) => {
        this.pairingCode = code;
        this.renderPill();
      },
      onStatus: () => this.renderPill(),
      onOutdated: (side) => {
        this.outdated = side;
        this.renderPill();
      },
      onConnection: (connected) => {
        this.connected = connected;
        this.renderPill();
      },
      log: this.options.log,
    };
    this.bridge = new DuhcordBridge(adapter);

    this.subscribe("CONNECTION_OPEN", () => this.startBridge());
    this.subscribe("CHANNEL_SELECT", () => setTimeout(() => this.reportSelected(), 0));
    this.subscribe("LOAD_MESSAGES_SUCCESS", (event) => {
      if (event.channelId === this.selectedChannel()) this.reportSelected();
    });
    this.subscribe("MESSAGE_CREATE", (event) => this.onMessage(event.channelId ?? event.message?.channel_id, event.message));
    this.subscribe("MESSAGE_UPDATE", (event) => this.onMessage(event.message?.channel_id, event.message));
    this.subscribe("MESSAGE_DELETE", (event) => this.bridge?.reportDeleted(event.channelId, [event.id]));
    this.subscribe("MESSAGE_DELETE_BULK", (event) => this.bridge?.reportDeleted(event.channelId, event.ids ?? []));

    this.installUi();
    this.startBridge();
    this.reportSelected();
  }

  stop(): void {
    for (const [type, handler] of this.subscriptions) this.discord?.Dispatcher.unsubscribe(type, handler);
    this.subscriptions.length = 0;
    this.bridge?.stop();
    this.bridge = null;
    this.observer?.disconnect();
    this.observer = null;
    this.pill?.remove();
    this.pill = null;
    document.getElementById(STYLE_ID)?.remove();
    document.querySelectorAll(`.${FOLDED}`).forEach((el) => el.classList.remove(FOLDED));
    document.removeEventListener("click", this.onDocumentClick, true);
    this.reported.clear();
  }

  // ---- Discord → companion ---------------------------------------------------------------------

  private subscribe(type: string, handler: (event: any) => void): void {
    const safe = (event: any) => {
      try {
        handler(event);
      } catch (error) {
        this.options.log?.(`${type} handler failed`, error);
      }
    };
    this.discord!.Dispatcher.subscribe(type, safe);
    this.subscriptions.push([type, safe]);
  }

  private startBridge(): void {
    const me = this.discord?.UserStore.getCurrentUser();
    if (me && isSnowflake(me.id)) this.bridge?.start(me.id);
  }

  private selectedChannel(): string | null {
    const id = this.discord?.SelectedChannelStore.getChannelId();
    return isSnowflake(id) ? id : null;
  }

  /** The DM's info, or null for anything that isn't a 1:1 DM (group DMs are never reported). */
  private dmInfo(channelId: string | null | undefined): Dm | null {
    if (!this.discord || !isSnowflake(channelId)) return null;
    const channel = this.discord.ChannelStore.getChannel(channelId);
    if (!channel || channel.type !== DM_CHANNEL) return null;
    const recipients: unknown[] = channel.recipients ?? channel.rawRecipients?.map((r: any) => r.id) ?? [];
    if (recipients.length !== 1) return null;
    const peerId = typeof recipients[0] === "string" ? recipients[0] : (recipients[0] as any)?.id;
    const me = this.discord.UserStore.getCurrentUser();
    const peer = this.discord.UserStore.getUser(peerId);
    if (!me || !isSnowflake(peerId)) return null;
    return {
      channelId,
      me: { id: me.id, username: me.username, globalName: me.globalName ?? null },
      peer: {
        id: peerId,
        username: peer?.username ?? peerId,
        globalName: peer?.globalName ?? null,
        avatarUrl: typeof peer?.getAvatarURL === "function" ? safeCall(() => peer.getAvatarURL(undefined, 128)) : null,
      },
    };
  }

  private reportSelected(): void {
    this.renderPill();
    const channelId = this.selectedChannel();
    const dm = this.dmInfo(channelId);
    if (!dm || !this.bridge?.isReady) return;
    this.reportDm(dm);
    const collection = this.discord!.MessageStore.getMessages(dm.channelId);
    const records: any[] = collection?.toArray?.() ?? collection?._array ?? [];
    const wire = records.map(toWire).filter((m): m is WireMessage => m !== null);
    const oldest = wire.length ? wire.reduce((a, b) => (a.id.length < b.id.length || (a.id.length === b.id.length && a.id < b.id) ? a : b)).id : null;
    const exhausted = collection?.hasMoreBefore === false;
    this.bridge.reportMessages(dm.channelId, wire, oldest, exhausted);
  }

  private reportDm(dm: Dm): void {
    if (this.reported.has(dm.channelId)) return;
    this.reported.add(dm.channelId);
    this.bridge?.reportDm(dm);
  }

  private onMessage(channelId: string | undefined, message: any): void {
    const wire = toWire(message);
    if (!wire || !isPrivateContent(wire.content)) return;
    const dm = this.dmInfo(channelId);
    if (!dm || !this.bridge?.isReady) return;
    this.reportDm(dm);
    this.bridge.reportMessages(dm.channelId, [wire], null, false);
  }

  // ---- companion → Discord ---------------------------------------------------------------------

  private async post(channelId: string, content: string): Promise<string> {
    const nonce = makeNonce();
    // Discord echoes the nonce on the gateway's MESSAGE_CREATE, which confirms the send (and gives
    // the ID) even when the REST reply isn't shaped the way we expect.
    const echo = this.waitForEcho(channelId, nonce, ECHO_TIMEOUT_MS);
    let response: any;
    try {
      response = await this.discord!.RestAPI.post({
        url: `/channels/${channelId}/messages`,
        body: { content, nonce, tts: false, flags: 0 },
      });
    } catch (error) {
      echo.cancel();
      throw error;
    }
    const status = response?.status;
    if (response?.ok === false || (typeof status === "number" && status >= 400)) {
      echo.cancel();
      throw { status: typeof status === "number" ? status : 0 };
    }
    const id = messageIdFrom(response);
    if (id) {
      echo.cancel();
      return id;
    }
    const echoed = await echo.promise;
    if (echoed) return echoed;
    this.options.log?.("send: Discord's reply had no message ID", describeShape(response));
    throw new Error("Discord didn't confirm the message; check the DM, then try again");
  }

  private waitForEcho(channelId: string, nonce: string, timeoutMs: number): { promise: Promise<string | null>; cancel(): void } {
    const dispatcher = this.discord!.Dispatcher;
    let finish: (id: string | null) => void = () => {};
    const promise = new Promise<string | null>((resolve) => (finish = resolve));
    const handler = (event: any) => {
      try {
        const message = event?.message;
        const channel = event?.channelId ?? message?.channel_id;
        if (message?.nonce === nonce && channel === channelId && isSnowflake(message.id)) done(message.id);
      } catch {
        // ignore
      }
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    let settled = false;
    const done = (id: string | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        dispatcher.unsubscribe("MESSAGE_CREATE", handler);
      } catch {
        // ignore
      }
      finish(id);
    };
    try {
      dispatcher.subscribe("MESSAGE_CREATE", handler);
    } catch {
      done(null);
    }
    return { promise, cancel: () => done(null) };
  }

  private async history(channelId: string, before: string | null): Promise<History> {
    const query: Record<string, string | number> = { limit: HISTORY_PAGE };
    if (before) query.before = before;
    const response = await this.discord!.RestAPI.get({ url: `/channels/${channelId}/messages`, query, retries: 2 });
    const body: any[] = Array.isArray(response?.body) ? response.body : [];
    return {
      messages: body.map(toWire).filter((m): m is WireMessage => m !== null),
      exhausted: body.length < HISTORY_PAGE,
    };
  }

  // ---- UI --------------------------------------------------------------------------------------

  private installUi(): void {
    if (!document.getElementById(STYLE_ID)) {
      const style = document.createElement("style");
      style.id = STYLE_ID;
      style.textContent = CSS;
      document.head.append(style);
    }
    const pill = document.createElement("button");
    pill.id = PILL_ID;
    pill.type = "button";
    pill.addEventListener("click", () => {
      const channelId = this.selectedChannel();
      if (channelId && this.bridge?.isReady) this.bridge.open(channelId);
    });
    document.body.append(pill);
    this.pill = pill;

    const fold = (root: ParentNode) => {
      root.querySelectorAll?.('[id^="message-content-"]').forEach((el) => {
        if (el.classList.contains(FOLDED)) return;
        if (isPrivateContent(lastLineText(el))) el.classList.add(FOLDED);
      });
    };
    fold(document);
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        mutation.addedNodes.forEach((node) => {
          if (node instanceof Element) {
            if (node.id?.startsWith("message-content-")) fold(node.parentElement ?? node);
            else fold(node);
          }
        });
        if (mutation.type === "characterData") {
          const el = mutation.target.parentElement?.closest('[id^="message-content-"]');
          if (el && !el.classList.contains(FOLDED) && isPrivateContent(lastLineText(el))) el.classList.add(FOLDED);
        }
      }
    });
    this.observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    document.addEventListener("click", this.onDocumentClick, true);
    this.renderPill();
  }

  private readonly onDocumentClick = (event: MouseEvent) => {
    const target = event.target instanceof Element ? event.target.closest(`.${FOLDED}`) : null;
    if (!target) return;
    const channelId = this.selectedChannel();
    if (channelId && this.bridge?.isReady) this.bridge.open(channelId);
  };

  private renderPill(): void {
    const pill = this.pill;
    if (!pill) return;
    const channelId = this.selectedChannel();
    const isDm = this.dmInfo(channelId) !== null;
    let text = "";
    let tone = "";
    let title = "Duhcord Private";
    if (this.outdated) {
      text = this.outdated === "plugin" ? "🔒 Update the Duhcord Private plugin" : "🔒 Update Duhcord Companion";
      tone = "warn";
      title = this.outdated === "plugin"
        ? "This plugin is older than your Duhcord Companion. Open the companion to update it."
        : "Your Duhcord Companion is older than this plugin. Update it from its window or tray menu.";
    } else if (this.pairingCode) {
      text = `🔒 Code ${this.pairingCode} · allow it in Duhcord Companion`;
      tone = "warn";
    } else if (!isDm) {
      text = "";
    } else if (!this.connected) {
      text = "🔒 Companion not running";
      tone = "muted";
      title = "Start Duhcord Companion to chat privately";
    } else {
      const status: Status | undefined = channelId ? this.bridge?.status(channelId) : undefined;
      switch (status?.state) {
        case "ready":
          text = status.verified ? "🔒 Private · verified" : "🔒 Private";
          tone = status.newKey ? "warn" : status.verified ? "ok" : "";
          if (status.newKey) text = "🔒 Private · new key";
          break;
        case "request":
          text = "🔒 Wants to chat privately";
          tone = "warn";
          break;
        case "waiting":
          text = "🔒 Private · waiting for their key";
          tone = "muted";
          break;
        case "locked":
          text = "🔒 Companion locked";
          tone = "muted";
          break;
        case "unconfirmed":
          text = "🔒 Private · waiting for them to accept your key";
          tone = "muted";
          break;
        case "outdated":
          text = "🔒 They use a newer version · update Duhcord Companion";
          tone = "warn";
          break;
        default:
          text = "🔒 Private";
          tone = "muted";
      }
      title = "Open this chat in Duhcord Companion";
    }
    pill.textContent = text;
    pill.title = title;
    pill.dataset.tone = tone;
    pill.style.display = text ? "inline-flex" : "none";
  }
}

function lastLineText(el: Element): string {
  const text = (el as HTMLElement).innerText ?? el.textContent ?? "";
  return text.trimEnd().slice(text.trimEnd().lastIndexOf("\n") + 1).trim();
}

function makeNonce(): string {
  // Discord nonces are snowflake-shaped: time since the Discord epoch, shifted left by 22.
  const ms = BigInt(Date.now() - 1420070400000);
  return ((ms << 22n) + BigInt(Math.floor(Math.random() * 4096))).toString();
}

function safeCall<T>(fn: () => T): T | null {
  try {
    return fn();
  } catch {
    return null;
  }
}
