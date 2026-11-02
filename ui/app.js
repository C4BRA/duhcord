// Duhcord Companion UI. Runs only inside the companion's own Tauri windows.
// Decrypted text arrives over Tauri IPC and is only ever put in the DOM with textContent.

const tauri = window.__TAURI__;
// Rust command names are snake_case; Tauri converts the argument names but not the command name.
const invoke = (command, args) => tauri.core.invoke(command.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`), args);
const listen = (event, handler) => tauri.event.listen(event, handler);

const root = document.getElementById("root");
const params = new URLSearchParams(location.search);

/** Tiny element builder. Strings become text nodes, never HTML. */
function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith("on")) el.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === "class") el.className = value;
    else el.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

const HOSTS = {
  vencord: "Vencord",
  vesktop: "Vesktop",
  replugged: "Replugged",
  betterdiscord: "BetterDiscord",
};

function displayName(person) {
  return person.globalName || person.username;
}

/** Engine warnings use Discord markdown (`⚠️ *text*`); show them as plain text. */
function plainWarning(text) {
  return text.replace(/\*/g, "");
}

function statusChip(status) {
  if (status.state === "locked") return h("span", { class: "chip" }, "Locked");
  if (status.state === "request") return h("span", { class: "chip warn" }, "Wants to chat privately");
  if (status.newKey) return h("span", { class: "chip warn" }, "New key");
  if (status.state === "off") return h("span", { class: "chip" }, "Not private");
  if (status.state === "waiting") return h("span", { class: "chip" }, "Waiting for their key");
  const label = status.peerClass === "companion" ? "Private · Companion" : "Private";
  return h("span", { class: status.verified ? "chip ok" : "chip" }, status.verified ? `${label} · Verified` : label);
}

async function guarded(action, errorTarget) {
  try {
    await action();
    if (errorTarget) errorTarget.textContent = "";
  } catch (error) {
    if (errorTarget) errorTarget.textContent = String(error);
    else alert(String(error));
  }
}

function closeSheet(backdrop) {
  backdrop.remove();
  if (deferredRender) {
    const render = deferredRender;
    deferredRender = null;
    rerender(render);
  }
}

function sheet(...children) {
  const backdrop = h("div", { class: "sheet", role: "dialog", "aria-modal": "true" }, h("div", { class: "card" }, ...children));
  backdrop.addEventListener("click", (event) => {
    if (event.target === backdrop) closeSheet(backdrop);
  });
  document.body.append(backdrop);
  return backdrop;
}

// ---- main window -------------------------------------------------------------------------------

async function renderMain() {
  const overview = await invoke("overview");
  const chatsByAccount = new Map();
  const devicesByAccount = new Map();
  for (const account of overview.accounts) {
    if (account.locked) continue;
    chatsByAccount.set(account.userId, await invoke("chats", { userId: account.userId }).catch(() => []));
    devicesByAccount.set(account.userId, await invoke("ownDevices", { userId: account.userId }).catch(() => []));
  }

  const content = h("div", { class: "scroll" });

  for (const request of overview.pairingRequests) {
    const error = h("p", { class: "error" });
    content.append(
      h(
        "div",
        { class: "card attention" },
        h("p", {}, h("strong", {}, `${HOSTS[request.host] ?? request.host} wants to connect`), ` (Discord account ${request.userId})`),
        h("p", { class: "muted" }, "Allow only if Discord shows this same code:"),
        h("p", { class: "code mono" }, request.code),
        h(
          "div",
          { class: "row" },
          h("button", { class: "primary", onClick: () => guarded(() => invoke("approvePairing", { conn: request.conn }), error) }, "Allow"),
          h("button", { onClick: () => guarded(() => invoke("denyPairing", { conn: request.conn }), error) }, "Deny"),
        ),
        error,
      ),
    );
  }

  if (overview.locked) {
    content.append(
      h(
        "div",
        { class: "card attention" },
        h("p", {}, h("strong", {}, "The companion is locked.")),
        h("p", { class: "muted" }, "Decrypted messages were cleared from memory. Nothing can be sent until you unlock."),
        h("button", { class: "primary", onClick: () => guarded(() => invoke("setLocked", { locked: false })) }, "Unlock"),
      ),
    );
  }

  content.append(h("h2", {}, "Private chats"));
  if (overview.accounts.length === 0) {
    content.append(
      h(
        "div",
        { class: "card" },
        h("p", {}, "No Discord account is connected yet."),
        h("p", { class: "muted" }, "Install the plugin for your Discord mod below and turn it on. It will show a 6-digit code here to approve."),
      ),
    );
  }
  for (const account of overview.accounts) {
    const card = h(
      "div",
      { class: "card" },
      h(
        "div",
        { class: "row" },
        h("div", { class: "grow" }, h("strong", {}, account.username ?? `Discord account ${account.userId}`)),
        account.hosts.length
          ? h("span", { class: "chip ok" }, account.hosts.map((host) => HOSTS[host] ?? host).join(", "))
          : h("span", { class: "chip" }, "Discord not connected"),
      ),
    );
    if (account.locked) {
      card.append(h("p", { class: "error" }, `The key store is locked: ${account.locked}`));
    } else {
      card.append(h("p", { class: "muted" }, "Your key code: ", h("span", { class: "mono" }, account.keyCode)));
      const chats = chatsByAccount.get(account.userId) ?? [];
      if (chats.length === 0) card.append(h("p", { class: "muted" }, "Open a DM in Discord and click the 🔒 Private button."));
      for (const chat of chats) {
        card.append(
          h(
            "button",
            { class: "chat-item", onClick: () => invoke("openChat", { userId: account.userId, channelId: chat.channelId }) },
            h("span", { class: "grow" }, displayName(chat.peer), h("span", { class: "muted" }, ` @${chat.peer.username}`)),
            statusChip(chat.status),
          ),
        );
      }
      const devices = (devicesByAccount.get(account.userId) ?? []).filter((device) => device.trust !== "rejected");
      if (devices.length) {
        card.append(h("h2", {}, "Your Macs"));
        for (const device of devices) {
          const error = h("p", { class: "error" });
          card.append(
            h(
              "div",
              { class: "row" },
              h("span", { class: "grow" }, h("span", { class: "mono" }, device.keyCode), device.trust === "pending" ? " · waiting for approval" : " · approved"),
              device.trust === "pending" &&
                h("button", { class: "primary", onClick: () => guarded(() => invoke("setOwnDevice", { userId: account.userId, key: device.key, accept: true }), error) }, "Approve"),
              device.trust === "pending" &&
                h("button", { onClick: () => guarded(() => invoke("setOwnDevice", { userId: account.userId, key: device.key, accept: false }), error) }, "Reject"),
            ),
            error,
          );
        }
        card.append(h("p", { class: "muted" }, "Approve only a key code that Duhcord on your Mac shows in Settings → Privacy. Approved Macs can read what you send from here."));
      }
    }
    content.append(card);
  }

  content.append(h("h2", {}, "Connect your Discord"));
  const installError = h("p", { class: "error" });
  const installed = h("p", { class: "muted" });
  const install = (host) =>
    guarded(async () => {
      const result = await invoke("installPlugin", { host });
      installed.textContent = `Installed to ${result.path}. Turn it on in Discord's plugin settings, then approve the code here.`;
    }, installError);
  content.append(
    h(
      "div",
      { class: "card" },
      h("div", { class: "row" }, h("span", { class: "grow" }, h("strong", {}, "BetterDiscord")), h("button", { onClick: () => install("betterdiscord") }, "Install plugin")),
      h("p", { class: "muted" }, "Then: User Settings → Plugins → DuhcordPrivate → on."),
      h("div", { class: "row" }, h("span", { class: "grow" }, h("strong", {}, "Replugged")), h("button", { onClick: () => install("replugged") }, "Install plugin")),
      h("p", { class: "muted" }, "Then: Settings → Replugged → Plugins → Duhcord Private → on."),
      h("div", { class: "row" }, h("span", { class: "grow" }, h("strong", {}, "Vencord / Vesktop"))),
      h("p", { class: "muted" }, "Vencord compiles plugins in. Copy plugins/vencord/duhcordPrivate from the release into Vencord's src/userplugins, then run pnpm build && pnpm inject (Vesktop: point it at that build)."),
      installed,
      installError,
    ),
  );

  if (overview.pairings.length) {
    content.append(h("h2", {}, "Connected plugins"));
    const card = h("div", { class: "card" });
    for (const pairing of overview.pairings) {
      card.append(
        h(
          "div",
          { class: "row" },
          h("span", { class: "grow" }, `${HOSTS[pairing.host] ?? pairing.host} · account ${pairing.userId}`, h("span", { class: "muted" }, ` · since ${new Date(pairing.createdAt * 1000).toLocaleDateString()}`)),
          h("button", { class: "danger", onClick: () => guarded(() => invoke("revokePairing", { tokenHash: pairing.tokenHash })) }, "Disconnect"),
        ),
      );
    }
    content.append(card);
  }

  content.append(h("h2", {}, "Settings"));
  const autostart = h("input", { type: "checkbox", id: "autostart", checked: overview.autostart });
  autostart.addEventListener("change", () => guarded(() => invoke("setAutostart", { enabled: autostart.checked })));
  content.append(
    h(
      "div",
      { class: "card" },
      h("div", { class: "row" }, autostart, h("label", { for: "autostart" }, "Start with my computer (in the tray)")),
      h("p", { class: "muted" }, `Bridge on 127.0.0.1:${overview.bridgePort} · version ${overview.version}`),
    ),
  );

  root.replaceChildren(
    h(
      "header",
      {},
      h("div", { class: "grow" }, h("h1", {}, "Duhcord Companion"), h("div", { class: "sub" }, "Your key and decrypted messages stay in this app, never in Discord.")),
      !overview.locked && h("button", { onClick: () => guarded(() => invoke("setLocked", { locked: true })) }, "Lock"),
    ),
    content,
  );
}

// ---- chat window -------------------------------------------------------------------------------

const imageUrls = new Map();

async function loadImage(chat, message, attachmentId, container) {
  const key = `${message.id}/${attachmentId}`;
  let url = imageUrls.get(key);
  if (!url) {
    const bytes = await invoke("fetchImage", { userId, channelId, messageId: message.id, attachmentId });
    url = URL.createObjectURL(new Blob([bytes]));
    imageUrls.set(key, url);
  }
  container.replaceChildren(h("img", { src: url, alt: "Private image" }));
}

const userId = params.get("user");
const channelId = params.get("channel");
let draft = "";

function acceptSheet(chat) {
  const keys = chat.pendingKeys.map((key) => key.key);
  const error = h("p", { class: "error" });
  const numberEl = h("p", { class: "number mono" }, "…");
  const input = h("input", { type: "text", placeholder: "Type the 60 digits they read to you (optional)", inputmode: "numeric" });
  invoke("safetyNumber", { userId, channelId, accepting: keys }).then((number) => (numberEl.textContent = number ?? "—"));
  const companion = chat.pendingKeys.some((key) => key.class === "companion");
  const backdrop = sheet(
    h("h1", {}, `New key for ${displayName(chat.peer)}`),
    h("p", {}, `${displayName(chat.peer)} has a new key. Accept it only if you expected this, for example a new Mac or a reinstall. Otherwise someone may be trying to read your messages.`),
    companion && h("p", { class: "muted" }, "This key belongs to a Duhcord Companion (Vencord, Replugged or BetterDiscord on a PC), not to Duhcord on a Mac."),
    ...chat.pendingKeys.map((key) => h("p", { class: "muted" }, "Key code ", h("span", { class: "mono" }, key.keyCode))),
    h("h2", {}, "Safety number with this key"),
    numberEl,
    h("p", { class: "muted" }, "Compare it with what they see, in person or on a call you trust."),
    input,
    h(
      "div",
      { class: "row", style: "margin-top:10px" },
      h(
        "button",
        {
          class: "primary",
          onClick: () =>
            guarded(async () => {
              const compared = input.value.trim() || null;
              await invoke("acceptKeys", { userId, channelId, keys, compared });
              closeSheet(backdrop);
            }, error),
        },
        "Accept",
      ),
      h(
        "button",
        {
          class: "danger",
          onClick: () =>
            guarded(async () => {
              await invoke("rejectKeys", { userId, channelId, keys });
              closeSheet(backdrop);
            }, error),
        },
        "Reject",
      ),
      h("button", { onClick: () => closeSheet(backdrop) }, "Later"),
    ),
    error,
  );
}

function safetySheet(chat) {
  const error = h("p", { class: "error" });
  const backdrop = sheet(
    h("h1", {}, "Safety number"),
    h("p", {}, `Compare this with ${displayName(chat.peer)}. If every digit matches, nobody else can read this chat.`),
    h("p", { class: "number mono" }, chat.safetyNumber ?? "No keys yet"),
    h("p", { class: "muted" }, "Your key code: ", h("span", { class: "mono" }, chat.myKeyCode)),
    ...chat.acceptedKeys.map((key) =>
      h("p", { class: "muted" }, `${key.class === "companion" ? "Companion" : "Duhcord"} key: `, h("span", { class: "mono" }, key.keyCode)),
    ),
    h(
      "div",
      { class: "row" },
      !chat.status.verified &&
        chat.safetyNumber &&
        h(
          "button",
          {
            class: "primary",
            onClick: () =>
              guarded(async () => {
                await invoke("markVerified", { userId, channelId });
                closeSheet(backdrop);
              }, error),
          },
          "They match, mark as verified",
        ),
      h("button", { onClick: () => closeSheet(backdrop) }, "Close"),
    ),
    error,
  );
}

async function renderChat() {
  let chat;
  try {
    chat = await invoke("chat", { userId, channelId });
  } catch (error) {
    root.replaceChildren(h("div", { class: "empty" }, String(error), h("p", {}, "Open the DM in Discord so the plugin can show it to the companion.")));
    return;
  }
  document.title = `${displayName(chat.peer)} · Private`;
  tauri.window?.getCurrentWindow?.().setTitle(document.title).catch(() => {});

  const oldList = root.querySelector(".messages");
  const stickToBottom = !oldList || oldList.scrollHeight - oldList.scrollTop - oldList.clientHeight < 40;
  const oldInput = root.querySelector("textarea");
  if (oldInput) draft = oldInput.value;

  const error = h("p", { class: "error", style: "margin:0 16px" });
  const banner = (() => {
    const status = chat.status;
    if (status.state === "locked") return h("div", { class: "banner" }, "The companion is locked. Unlock it from the main window.");
    if (status.state === "request")
      return h(
        "div",
        { class: "banner" },
        `${displayName(chat.peer)} wants to chat privately.`,
        h("div", { class: "row" }, h("button", { class: "primary", onClick: () => guarded(() => invoke("setPrivate", { userId, channelId, enabled: true }), error) }, "Accept")),
      );
    if (status.state === "off")
      return h(
        "div",
        { class: "banner" },
        "Private is off for this chat. Turning it on sends your key to them through Discord.",
        h("div", { class: "row" }, h("button", { class: "primary", onClick: () => guarded(() => invoke("setPrivate", { userId, channelId, enabled: true }), error) }, "Turn on Private")),
      );
    if (status.state === "waiting")
      return h("div", { class: "banner" }, `Waiting for ${displayName(chat.peer)}'s key. They need Duhcord (with Companion chat on) or the Companion.`);
    if (status.newKey)
      return h(
        "div",
        { class: "banner" },
        `${displayName(chat.peer)} has a new key.`,
        h("div", { class: "row" }, h("button", { class: "primary", onClick: () => acceptSheet(chat) }, "Review")),
      );
    return null;
  })();

  const list = h("div", { class: "messages" });
  if (chat.messages.length === 0) list.append(h("div", { class: "empty" }, "No private messages loaded yet."));
  for (const message of chat.messages) {
    const bubble = h("div", { class: message.fromMe ? "bubble mine" : "bubble" });
    bubble.append(h("div", {}, message.text));
    for (const attachmentId of message.images) {
      const holder = h("div", {});
      const button = h("button", { onClick: () => guarded(() => loadImage(chat, message, attachmentId, holder), holder) }, "Show image");
      holder.append(button);
      if (imageUrls.has(`${message.id}/${attachmentId}`)) loadImage(chat, message, attachmentId, holder);
      bubble.append(holder);
    }
    for (const warning of message.warnings) bubble.append(h("div", { class: "warning" }, plainWarning(warning)));
    bubble.append(h("div", { class: "meta" }, new Date(message.timestampMs).toLocaleString()));
    list.append(bubble);
  }

  const canSend = chat.status.state === "ready";
  const input = h("textarea", {
    placeholder: canSend ? `Private message to ${displayName(chat.peer)}` : "Private isn't ready yet",
    disabled: !canSend,
    maxlength: 1500,
    "aria-label": "Message",
  });
  input.value = draft;
  const send = async () => {
    const text = input.value;
    if (!text.trim()) return;
    input.value = "";
    draft = "";
    await guarded(() => invoke("sendText", { userId, channelId, text }), error).catch(() => {});
    if (error.textContent) {
      input.value = text;
      draft = text;
    }
  };
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      send();
    }
  });

  root.replaceChildren(
    h(
      "header",
      {},
      h("div", { class: "grow" }, h("h1", {}, displayName(chat.peer)), h("div", { class: "sub" }, `@${chat.peer.username}`)),
      statusChip(chat.status),
      h("button", { onClick: () => safetySheet(chat), title: "Safety number" }, "🔐"),
    ),
    banner,
    list,
    error,
    h("div", { class: "composer" }, input, h("button", { class: "primary", disabled: !canSend, onClick: send }, "Send")),
  );
  if (stickToBottom) list.scrollTop = list.scrollHeight;
  else if (oldList) list.scrollTop = oldList.scrollTop;
  if (canSend && document.hasFocus()) input.focus();
}

// ---- boot --------------------------------------------------------------------------------------

let queued = false;
let deferredRender = null;
function rerender(render) {
  if (queued) return;
  queued = true;
  requestAnimationFrame(async () => {
    queued = false;
    if (document.querySelector(".sheet")) {
      deferredRender = render; // don't yank a sheet the user is reading; render when it closes
      return;
    }
    await render().catch((error) => root.replaceChildren(h("div", { class: "empty error" }, String(error))));
  });
}

if (params.get("view") === "chat") {
  rerender(renderChat);
  listen("companion", ({ payload }) => {
    const mine = payload.userId === userId && (payload.channelId === undefined || payload.channelId === channelId);
    if (mine || payload.type === "accountsChanged") rerender(renderChat);
  });
  addEventListener("beforeunload", () => imageUrls.forEach((url) => URL.revokeObjectURL(url)));
} else {
  rerender(renderMain);
  listen("companion", () => rerender(renderMain));
}
