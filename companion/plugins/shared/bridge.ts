// Bridge client shared by the Vencord, Replugged and BetterDiscord plugins (spec/BRIDGE.md).
//
// The plugin is a ciphertext pipe: it reports private messages (last line starts with `dhc2:`)
// to the companion and posts what the companion asks it to post. It has no key, does no crypto
// and never sees plaintext, so nothing here is secret (the pairing token only keeps other local
// apps off the bridge).

export type Host = "vencord" | "vesktop" | "replugged" | "betterdiscord";
export type State = "off" | "request" | "waiting" | "ready" | "locked";

export interface WireAttachment {
  id: string;
  filename: string;
  size: number;
  url: string;
}

export interface WireMessage {
  id: string;
  authorId: string;
  content: string;
  editedAt: string | null;
  attachments: WireAttachment[];
}

export interface Person {
  id: string;
  username: string;
  globalName?: string | null;
  avatarUrl?: string | null;
}

export interface Dm {
  channelId: string;
  peer: Person;
  me: Person;
}

export interface Status {
  channelId: string;
  state: State;
  verified: boolean;
  newKey: boolean;
  peerClass: "duhcord" | "companion" | null;
}

export interface History {
  /** Every message of the page (the bridge filters), any order. */
  messages: WireMessage[];
  /** No older messages exist. */
  exhausted: boolean;
}

/** Minimal WebSocket surface, so tests and other transports can stand in. */
export interface SocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((event: unknown) => void) | null;
  onclose: ((event: unknown) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
}

/** What each mod provides. Everything Discord-specific lives behind this. */
export interface Adapter {
  host: Host;
  pluginVersion: string;
  /** Ports to try, in order. Mods with file access read `bridge.json` first. */
  ports(): Promise<number[]> | number[];
  openSocket(url: string): SocketLike;
  loadToken(userId: string): Promise<string | null> | string | null;
  saveToken(userId: string, token: string | null): Promise<void> | void;
  /** Posts `content` verbatim in the channel and resolves with the new message ID. */
  sendMessage(channelId: string, content: string): Promise<string>;
  editMessage(channelId: string, messageId: string, content: string): Promise<void>;
  deleteMessage(channelId: string, messageId: string): Promise<void>;
  /** Messages before `before` (or the newest when null), oldest → newest. */
  loadHistory(channelId: string, before: string | null): Promise<History>;
  /** Re-reports the open DM after (re)connecting. */
  onReady?(): void;
  onPairing?(code: string | null): void;
  onStatus?(status: Status): void;
  onConnection?(connected: boolean): void;
  log?(...args: unknown[]): void;
}

export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORTS = [47823, 47824, 47825, 47826, 47827];
const PREFIX = "dhc2:";
const SNOWFLAKE = /^\d{1,20}$/;
const OPEN = 1;

/** True when Duhcord would read this content as a private frame (spec/PROTOCOL.md §1). */
export function isPrivateContent(content: unknown): content is string {
  if (typeof content !== "string" || content.length > 2000) return false;
  const lastLine = content.slice(content.lastIndexOf("\n") + 1);
  return lastLine.startsWith(PREFIX) && lastLine.length > PREFIX.length;
}

export function isSnowflake(value: unknown): value is string {
  return typeof value === "string" && SNOWFLAKE.test(value);
}

export function onlyPrivate(messages: WireMessage[]): WireMessage[] {
  return messages.filter((message) => isPrivateContent(message.content));
}

export class DuhcordBridge {
  private socket: SocketLike | null = null;
  private ready = false;
  private stopped = true;
  private userId: string | null = null;
  private retry = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly statuses = new Map<string, Status>();
  private readonly dms = new Map<string, Dm>();

  private readonly adapter: Adapter;

  constructor(adapter: Adapter) {
    this.adapter = adapter;
  }

  get isReady(): boolean {
    return this.ready;
  }

  status(channelId: string): Status | undefined {
    return this.statuses.get(channelId);
  }

  /** Starts (or restarts) for the logged-in Discord user. */
  start(userId: string): void {
    if (!isSnowflake(userId)) return;
    if (!this.stopped && this.userId === userId) return;
    this.stop();
    this.userId = userId;
    this.stopped = false;
    this.retry = 0;
    void this.connect();
  }

  stop(): void {
    const wasRunning = !this.stopped;
    this.stopped = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.ready = false;
    const socket = this.socket;
    this.socket = null;
    if (socket) {
      socket.onclose = socket.onerror = socket.onmessage = socket.onopen = null;
      try {
        socket.close(1000, "plugin stopped");
      } catch {
        /* already closed */
      }
    }
    if (wasRunning) {
      this.adapter.onPairing?.(null);
      this.adapter.onConnection?.(false);
    }
  }

  /** Reports a 1:1 DM. Group DMs must never be passed here. */
  reportDm(dm: Dm): void {
    if (!isSnowflake(dm.channelId) || !isSnowflake(dm.peer.id) || !isSnowflake(dm.me.id)) return;
    this.dms.set(dm.channelId, dm);
    this.send({
      t: "dm",
      channelId: dm.channelId,
      peer: {
        id: dm.peer.id,
        username: dm.peer.username,
        globalName: dm.peer.globalName ?? null,
        avatarUrl: dm.peer.avatarUrl ?? null,
      },
      me: { id: dm.me.id, username: dm.me.username },
    });
  }

  reportMessages(channelId: string, messages: WireMessage[], before: string | null, exhausted: boolean): void {
    if (!this.dms.has(channelId)) return;
    const relevant = onlyPrivate(messages).sort((a, b) => compareSnowflakes(a.id, b.id));
    if (relevant.length === 0 && before === null && !exhausted) return;
    this.send({ t: "messages", channelId, messages: relevant, before, exhausted });
  }

  reportDeleted(channelId: string, ids: string[]): void {
    if (!this.dms.has(channelId) || ids.length === 0) return;
    this.send({ t: "deleted", channelId, ids: ids.filter(isSnowflake) });
  }

  /** The user clicked the plugin's Private button: the companion brings that chat forward. */
  open(channelId: string): void {
    if (isSnowflake(channelId)) this.send({ t: "open", channelId });
  }

  private send(frame: Record<string, unknown>): boolean {
    if (!this.ready || !this.socket || this.socket.readyState !== OPEN) return false;
    this.socket.send(JSON.stringify(frame));
    return true;
  }

  private raw(frame: Record<string, unknown>): void {
    if (this.socket && this.socket.readyState === OPEN) this.socket.send(JSON.stringify(frame));
  }

  private async connect(): Promise<void> {
    if (this.stopped || !this.userId) return;
    const userId = this.userId;
    let ports: number[];
    try {
      ports = await this.adapter.ports();
    } catch {
      ports = DEFAULT_PORTS;
    }
    if (ports.length === 0) ports = DEFAULT_PORTS;
    const port = ports[this.retry % ports.length];
    let socket: SocketLike;
    try {
      socket = this.adapter.openSocket(`ws://127.0.0.1:${port}/bridge`);
    } catch (error) {
      this.adapter.log?.("bridge socket failed", error);
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;
    socket.onopen = async () => {
      if (this.socket !== socket) return;
      let token: string | null = null;
      try {
        token = await this.adapter.loadToken(userId);
      } catch {
        token = null;
      }
      if (this.socket !== socket) return;
      socket.send(
        JSON.stringify({
          t: "hello",
          v: PROTOCOL_VERSION,
          host: this.adapter.host,
          plugin: this.adapter.pluginVersion,
          userId,
          token: typeof token === "string" && token.length > 0 ? token : null,
        }),
      );
    };
    socket.onmessage = (event) => {
      if (this.socket !== socket || typeof event.data !== "string") return;
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      void this.handle(frame).catch((error) => this.adapter.log?.("bridge frame failed", error));
    };
    socket.onerror = () => {};
    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = null;
      const wasReady = this.ready;
      this.ready = false;
      if (wasReady) this.adapter.onConnection?.(false);
      this.scheduleReconnect(wasReady);
    };
  }

  private scheduleReconnect(wasReady = false): void {
    if (this.stopped) return;
    if (wasReady) this.retry = 0;
    else this.retry += 1;
    // Cycle quickly through the port range, then back off up to 30 s.
    const round = Math.floor(this.retry / DEFAULT_PORTS.length);
    const delay = this.retry % DEFAULT_PORTS.length === 0 ? Math.min(30_000, 2_000 * 2 ** Math.min(round, 4)) : 150;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.connect();
    }, delay);
  }

  private async handle(frame: Record<string, unknown>): Promise<void> {
    switch (frame.t) {
      case "pairing":
        if (typeof frame.code === "string" && /^\d{6}$/.test(frame.code)) this.adapter.onPairing?.(frame.code);
        return;
      case "paired":
        if (typeof frame.token === "string" && this.userId) await this.adapter.saveToken(this.userId, frame.token);
        return;
      case "ready":
        this.ready = true;
        this.retry = 0;
        this.adapter.onPairing?.(null);
        this.adapter.onConnection?.(true);
        for (const dm of this.dms.values()) this.reportDm(dm);
        this.adapter.onReady?.();
        return;
      case "error":
        if (frame.code === "denied") {
          this.adapter.onPairing?.(null);
          if (this.userId) await this.adapter.saveToken(this.userId, null);
          // Don't nag: wait for the next start() (Discord restart or plugin toggle).
          this.stop();
        }
        return;
      case "status":
        return this.onStatus(frame);
      case "send":
        return this.onSend(frame);
      case "edit":
        return this.onEdit(frame);
      case "delete":
        return this.onDelete(frame);
      case "needHistory":
        return this.onNeedHistory(frame);
      default:
        return; // unknown frames are ignored
    }
  }

  private onStatus(frame: Record<string, unknown>): void {
    const states: State[] = ["off", "request", "waiting", "ready", "locked"];
    if (!isSnowflake(frame.channelId) || !states.includes(frame.state as State)) return;
    const status: Status = {
      channelId: frame.channelId,
      state: frame.state as State,
      verified: frame.verified === true,
      newKey: frame.newKey === true,
      peerClass: frame.peerClass === "duhcord" || frame.peerClass === "companion" ? frame.peerClass : null,
    };
    this.statuses.set(status.channelId, status);
    this.adapter.onStatus?.(status);
  }

  private async onSend(frame: Record<string, unknown>): Promise<void> {
    const nonce = typeof frame.nonce === "string" ? frame.nonce : "";
    if (!isSnowflake(frame.channelId) || !this.dms.has(frame.channelId)) {
      this.send({ t: "sendFailed", nonce, error: "unknown-channel" });
      return;
    }
    if (!isPrivateContent(frame.content)) {
      this.send({ t: "sendFailed", nonce, error: "not-private" });
      return;
    }
    try {
      const messageId = await this.adapter.sendMessage(frame.channelId, frame.content);
      this.send({ t: "sent", nonce, messageId });
    } catch (error) {
      this.send({ t: "sendFailed", nonce, error: errorText(error) });
    }
  }

  private async onEdit(frame: Record<string, unknown>): Promise<void> {
    const nonce = typeof frame.nonce === "string" ? frame.nonce : "";
    if (!isSnowflake(frame.channelId) || !isSnowflake(frame.messageId) || !this.dms.has(frame.channelId)) {
      this.send({ t: "sendFailed", nonce, error: "unknown-channel" });
      return;
    }
    if (!isPrivateContent(frame.content)) {
      this.send({ t: "sendFailed", nonce, error: "not-private" });
      return;
    }
    try {
      await this.adapter.editMessage(frame.channelId, frame.messageId, frame.content);
      this.send({ t: "sent", nonce, messageId: frame.messageId });
    } catch (error) {
      this.send({ t: "sendFailed", nonce, error: errorText(error) });
    }
  }

  private async onDelete(frame: Record<string, unknown>): Promise<void> {
    const nonce = typeof frame.nonce === "string" ? frame.nonce : "";
    if (!isSnowflake(frame.channelId) || !isSnowflake(frame.messageId) || !this.dms.has(frame.channelId)) {
      this.send({ t: "sendFailed", nonce, error: "unknown-channel" });
      return;
    }
    try {
      await this.adapter.deleteMessage(frame.channelId, frame.messageId);
      this.send({ t: "sent", nonce, messageId: frame.messageId });
    } catch (error) {
      this.send({ t: "sendFailed", nonce, error: errorText(error) });
    }
  }

  private async onNeedHistory(frame: Record<string, unknown>): Promise<void> {
    const channelId = frame.channelId;
    if (!isSnowflake(channelId) || !this.dms.has(channelId)) return;
    const before = isSnowflake(frame.before) ? frame.before : null;
    try {
      const history = await this.adapter.loadHistory(channelId, before);
      // Always answer, even with nothing private, so the companion knows where history ends.
      // `before` is the cursor for the next page: the oldest message of this one (any kind).
      const sorted = [...history.messages].sort((a, b) => compareSnowflakes(a.id, b.id));
      const cursor = sorted.length > 0 ? sorted[0].id : before;
      this.send({
        t: "messages",
        channelId,
        messages: onlyPrivate(sorted),
        before: cursor,
        exhausted: history.exhausted || sorted.length === 0,
      });
    } catch (error) {
      this.adapter.log?.("history failed", error);
    }
  }

  /** For tests: the raw socket (null when disconnected). */
  get _socket(): SocketLike | null {
    return this.socket;
  }

  /** For tests and diagnostics. */
  _rawSend(frame: Record<string, unknown>): void {
    this.raw(frame);
  }
}

export function compareSnowflakes(a: string, b: string): number {
  if (a.length !== b.length) return a.length - b.length;
  return a < b ? -1 : a > b ? 1 : 0;
}

function errorText(error: unknown): string {
  if (error && typeof error === "object") {
    const status = (error as { status?: unknown }).status;
    if (typeof status === "number") return `http-${status}`;
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string") return message.slice(0, 200);
  }
  return "failed";
}
