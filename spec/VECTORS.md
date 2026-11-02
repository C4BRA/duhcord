# Interop test vectors (protocol v3)

Both implementations (Swift in `Sources/DuhcordCore`, Rust in `companion/crates/protocol`) write a vectors file in this
format and check the other side's file. `.github/workflows/interop.yml` generates both fresh and checks both directions
whenever either side's private-messaging code or `spec/` changes. Byte vectors prove both sides **encode** identically;
[SCENARIOS.md](SCENARIOS.md) proves they **decide** identically.

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
- Handshakes (`0x32`, version 3), all required:

  | key | wantsReply | client | host | features | acceptedKeyIDs |
  |---|---|---|---|---|---|
  | alice | true | 0 | 0 | `0x030F` | none |
  | bob | false | 0 | 0 | `0x030F` | keyID(alice) |
  | carol | true | 1 | 4 | `0x0003` | none |
  | dave | false | 1 | 255 | `0x0003` | keyID(alice), keyID(bob), keyID(carol) (unknown host must still parse) |

- Safety numbers (one formula, §8): each entry names the keys on side `a` and `b`, and which of them are Companion
  (`client = 1`) keys:
  1. a=[alice], b=[bob] — both Duhcord.
  2. a=[alice, carol], b=[bob] — two keys on one side.
  3. a=[alice], b=[carol], bCompanion=[carol].
  4. a=[alice, bob], b=[carol, dave], bCompanion=[dave] — mixed side.
  5. a=[alice], b=[alice], aCompanion=[alice] — the same key on both sides with different clients.
  6. a=[bob], b=[alice] — the same pair as 1, sides swapped (must give the same number as 1).

## File format (`<impl>-vectors.json`)
```json
{
  "version": 3,
  "impl": "swift" | "rust",
  "channelId": "1100000000000000001",
  "publicKeys": { "alice": "<hex>", "bob": "<hex>", "carol": "<hex>", "dave": "<hex>" },
  "messages": [ { "name": "short", "sender": "alice", "recipients": ["bob"], "text": "hi",
                   "files": ["<45-byte PrivateFile hex>"], "content": "<full message content>" } ],
  "fileBlobs": [ { "file": "<45-byte hex>", "sealed": "<hex>", "plain": "<hex>" } ],
  "handshakes": [ { "key": "alice", "wantsReply": true, "client": 0, "host": 0, "features": 783,
                    "acceptedKeyIds": ["<8 hex digits>"], "content": "<content>" } ],
  "denseText": [ { "bytes": "<hex>", "text": "<string>" } ],
  "padme": [ [0, 1], [1, 1], [2, 2], [9, 10], [1000, 1024], [70000, 71680] ],
  "safetyNumbers": [ { "a": ["alice"], "b": ["bob"], "aCompanion": [], "bCompanion": [], "number": "<60 digits>" } ],
  "keyCodes": [ { "key": "alice", "code": "<30 digits>" } ],
  "rejects": [ { "why": "<short reason>", "content": "<content that must read as plain>" } ]
}
```
`denseText` byte strings: empty, `00`, `ff`, `0001`, `ffffffff`, 15 bytes `00..0e`, 16 bytes `00..0f`, 17 bytes
`00..10`, 100 bytes `SHA-512("a") ‖ SHA-512("b")[0..36]`.
The `padme` pairs above are expectations both sides must reproduce, not inputs to trust blindly — recompute them.

`rejects` (each must read as plain, i.e. `kind = plain`), all required:
- a `0x32` handshake one byte too long, and one byte too short for its `n`;
- a `0x32` handshake with `n = 9`;
- a `0x32` handshake with `flags = 0x02`;
- a `0x32` handshake with `client = 2`;
- a `0x31` message with `n = 0`;
- a v2 message: the `short` message's frame with type `0x21` under a `dhc2:` prefix;
- the `short` message's `dhc3:` frame with its type byte changed to `0x21`.

## Checks against the other side's file
- `version` is 3; public keys match ours (proves both derive the same key from the same seed).
- For every message: each named recipient opens `content` with `senders = [sender public key]`, `fromSelf = false`, and
  gets exactly `text` and `files`; the sender opens it with `fromSelf = true`. A wrong recipient (anyone not listed)
  gets nothing. Flipping any single byte of the frame (re-DenseText-encoded) fails to open.
- `fileBlobs`: our `openFile(sealed, file)` returns `plain`.
- `handshakes`: our encoder produces exactly their `content` from the listed fields, and our decoder reads their
  `content` back to the same fields.
- `denseText`, `padme`, `safetyNumbers`, `keyCodes`: our output equals theirs exactly.
- `rejects`: every entry reads as plain to us.
