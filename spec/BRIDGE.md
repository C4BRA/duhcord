# Companion ↔ plugin bridge (v1)

The plugin is a ciphertext pipe. **No plaintext and no private key ever crosses the bridge.** The companion only seals
text typed into its own window.

## Transport
- WebSocket on `127.0.0.1` only (never `0.0.0.0`/`::`), text frames of JSON, max 1 MiB per frame.
- Port: default `47823`; if busy, the next free one up to `47827`. The chosen port is written to
  `<config>/bridge.json` as `{"port": 47823, "version": 1}`, where `<config>` is
  `%APPDATA%\DuhcordCompanion` (Windows), `~/Library/Application Support/DuhcordCompanion` (macOS),
  `$XDG_CONFIG_HOME/DuhcordCompanion` or `~/.config/DuhcordCompanion` (Linux). Page-only plugins can't read files,
  so they try 47823…47827 in order.
- Accepted `Origin`: `https://discord.com`, `https://ptb.discord.com`, `https://canary.discord.com`, or absent
  (Vencord `native.ts` in Electron main). Anything else → close 1008. `Host` must be `127.0.0.1:<port>` or
  `localhost:<port>`.
- Rate limit: 200 frames/s per connection; at most 8 connections.

## Pairing
1. Plugin → `{"t":"hello","v":1,"host":"vencord|vesktop|replugged|betterdiscord|dorion","plugin":"1.0.0","userId":"<snowflake>","token":"<base64url>|null"}`
2. Known token for `(host,userId)` → `{"t":"ready","userId":"…","companion":"1.0.0"}`.
3. Otherwise the companion shows a pairing prompt with a 6-digit code and replies `{"t":"pairing","code":"123456"}`
   (the plugin shows the same code). When the user clicks Allow in the companion:
   `{"t":"paired","token":"<32 random bytes, base64url>"}` then `ready`. Deny → `{"t":"error","code":"denied"}`, close.
   The companion stores only SHA-256(token). Plugins store the token in their settings.
4. Before `ready`, every other frame → `{"t":"error","code":"unpaired"}`.

## Plugin → companion
- `dm`: `{"t":"dm","channelId","peer":{"id","username","globalName","avatarUrl"},"me":{"id","username"}}` — a 1:1
  DM the user has open or has private traffic in. Group DMs are never sent.
- `messages`: `{"t":"messages","channelId","messages":[Msg],"before":"<id>|null","exhausted":bool}` — loaded messages
  oldest→newest. Plugins send only messages whose last line starts with `dhc3:` (others are irrelevant).
  `Msg = {"id","authorId","content","editedAt":"ISO-8601|null","attachments":[{"id","filename","size","url"}]}`.
- `deleted`: `{"t":"deleted","channelId","ids":["…"]}`.
- `open`: `{"t":"open","channelId"}` — user clicked the plugin's "Private" button; companion focuses that chat.
- `sent` / `sendFailed`: `{"t":"sent","nonce","messageId"}` / `{"t":"sendFailed","nonce","error"}`.

## Companion → plugin
- `send`: `{"t":"send","nonce","channelId","content"}` — the plugin posts `content` verbatim as a normal message.
  Plugins must refuse (`sendFailed`, `"error":"not-private"`) if `content`'s last line doesn't start with `dhc3:`.
- `edit`: `{"t":"edit","nonce","channelId","messageId","content"}`, same rule. `delete`: `{"t":"delete","nonce","channelId","messageId"}`.
- `needHistory`: `{"t":"needHistory","channelId","before":"<id>|null"}` — plugin loads older messages and replies with
  `messages`.
- `status`: `{"t":"status","channelId","state":"off|request|waiting|unconfirmed|ready|outdated|locked","verified":bool,"newKey":bool,"peerClass":"duhcord|companion|null"}`
  — drives the plugin's button badge. Carries no message content. The states are those of PROTOCOL.md §6;
  `unconfirmed` = their key is accepted but they haven't accepted ours yet, `outdated` = they use a newer protocol.

Unknown `t` → ignored. Malformed frames → `{"t":"error","code":"bad-frame"}`; 10 of them → close.

## Attachments
The companion downloads `encrypted.bin` itself over HTTPS, only from `cdn.discordapp.com` or `media.discordapp.net`,
only when `size == sealedLength` of the matching `PrivateFile`, at most 50 MiB + 16, no redirects to other hosts.
