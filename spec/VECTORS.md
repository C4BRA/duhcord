# Interop test vectors

Both implementations (Swift in `Sources/DuhcordCore`, Rust in `companion/crates/protocol`) write a vectors file in this format and check
the other side's file. CI on macOS runs both directions; nothing ships unless both pass.

## Fixed inputs
- Keys: for each name in `alice`, `bob`, `carol`, `dave`, private key = `SHA-256("duhcord-vector-<name>")` (32 raw
  bytes, used as the X25519 raw private key; both libraries clamp).
- `channelId` = `"1100000000000000001"`. `sentAt` = `1700000000`.
- Messages to seal (sender → recipients, sender's own key always among the recipients like the apps do):
  1. `short`: alice → [bob], text `"hi"`.
  2. `unicode`: bob → [alice], text `"héllo 👋 世界\nsecond line"`.
  3. `compressible`: alice → [bob, carol, dave], text = `"private "` repeated 120 times (compression flag must be set).
  4. `incompressible`: carol → [alice], text = lowercase hex of `SHA-512("x")` (128 chars; may or may not compress — the
     reader must handle either).
  5. `files`: alice → [bob], text `"two pictures"`, files = two `PrivateFile`s with key = `SHA-256("file-0")` /
     `SHA-256("file-1")`, lengths 1000 / 70000, `sealedLength = padme(length)+16`, 640×480 JPEG / 1×1 PNG.
  6. `max-recipients`: dave → [alice, bob, carol] plus 5 more random keys generated at run time (only alice, bob, carol
     are checked).
- File sealing: `file-blob` = bytes `0..=255` repeated to 5000 bytes, kind PNG, 10×10. Record the `PrivateFile` and the
  sealed bytes.

## File format (`<impl>-vectors.json`)
```json
{
  "version": 1,
  "impl": "swift" | "rust",
  "channelId": "1100000000000000001",
  "publicKeys": { "alice": "<hex>", "bob": "<hex>", "carol": "<hex>", "dave": "<hex>" },
  "messages": [ { "name": "short", "sender": "alice", "recipients": ["bob"], "text": "hi",
                   "files": ["<45-byte PrivateFile hex>"], "content": "<full message content>" } ],
  "fileBlobs": [ { "file": "<45-byte hex>", "sealed": "<hex>", "plain": "<hex>" } ],
  "handshakes": [ { "key": "alice", "wantsReply": true, "content": "<content>" } ],
  "denseText": [ { "bytes": "<hex>", "text": "<string>" } ],
  "padme": [ [0, 1], [1, 1], [2, 2], [9, 10], [1000, 1024], [70000, 71680] ],
  "safetyNumbers": [ { "a": ["alice"], "b": ["bob"], "number": "<60 digits>" },
                      { "a": ["alice", "carol"], "b": ["bob"], "number": "…" } ],
  "keyCodes": [ { "key": "alice", "code": "<30 digits>" } ]
}
```
`denseText` byte strings: empty, `00`, `ff`, `0001`, `ffffffff`, 15 bytes `00..0e`, 16 bytes `00..0f`, 17 bytes
`00..10`, 100 bytes `SHA-512("a") ‖ SHA-512("b")[0..36]`. `handshakes`: alice 0x22 wantsReply true and bob false.
The `padme` pairs above are expectations both sides must reproduce, not inputs to trust blindly — recompute them.

## Checks against the other side's file
- Public keys match ours (proves both derive the same key from the same seed).
- For every message: each named recipient opens `content` with `senders = [sender public key]`, `fromSelf = false`, and
  gets exactly `text` and `files`; the sender opens it with `fromSelf = true`. A wrong recipient (anyone not listed)
  gets nothing. Flipping any single byte of the frame (re-DenseText-encoded) fails to open.
- `fileBlobs`: our `openFile(sealed, file)` returns `plain`.
- `handshakes`, `denseText`, `padme`, `safetyNumbers`, `keyCodes`: our output equals theirs exactly, and our decoder
  reads their handshake contents back to the same key/flag.

## Companion extensions (version 1, additive)
- `handshakes` entries carry `"class": 0|1`, `"host": <u8>`, `"features": <u16>` (0x22 entries: class 0, host 0,
  features 0x030F). Required entries: alice 0x22 wantsReply true; bob 0x22 wantsReply false; carol 0x23 wantsReply
  true host 4 features 0x0003; dave 0x23 wantsReply false host 255 features 0x0003 (unknown host must still parse).
- `safetyNumbers` entries may carry `"aCompanion"` / `"bCompanion"`: names (subset of that side) whose keys are class 1.
  Absent = none (v2). Required extra entries: a=[alice], b=[carol], bCompanion=[carol] (v3); a=[alice, bob],
  b=[carol, dave], bCompanion=[dave] (v3, mixed); a=[alice], b=[alice], aCompanion=[alice] (duplicate key across
  sides with mixed class).
- CI handoff: the Swift writer (`DUHCORD_WRITE_VECTORS=<path> swift test --filter CompanionInteropTests`) output is
  committed here as `interop/swift-vectors.json`; `cargo test -p duhcord-interop` checks it alongside the self-check.
