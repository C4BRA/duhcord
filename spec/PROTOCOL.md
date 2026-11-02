# Duhcord Private messaging — wire protocol

Authoritative source: `Sources/DuhcordCore/PrivateMessaging.swift` and
`Sources/Duhcord/PrivateChatController.swift`. If this file and the Swift ever disagree, the Swift wins and this file is
fixed. Everything here is byte-exact; all integers are big-endian.

## 1. Message content

Every private-mode Discord message is exactly:

    -# encrypted messaging by C4BRA/duhcord 🤫\n
    dhc2:<DenseText(frame)>

Readers look only at the **last line** (text after the last `\n`, or the whole content when there is no `\n`). It must
start with `dhc2:`; the rest must DenseText-decode, else the message is plain. The first byte of the decoded frame is its
type:

| type | meaning | size rule |
|---|---|---|
| `0x21` | encrypted message | > 27 bytes (see §4) |
| `0x22` | Duhcord handshake | **exactly 34 bytes**, otherwise plain |
| `0x23` | Companion handshake | **exactly 38 bytes**, otherwise plain (new; see §3) |
| other | plain | |

Content must be ≤ 2000 UTF-16 code units (Discord's limit, counted like JavaScript `String.length`).

## 2. DenseText (15 bits per UTF-16 unit)

Bits are taken MSB-first from the bytes. Each full 15-bit group `v` becomes one scalar:

- `0 ≤ v < 6592` → U+3400 + v
- `6592 ≤ v < 27584` → U+4E00 + (v − 6592)
- `27584 ≤ v < 32768` → U+AC00 + (v − 27584)

At the end, with `b` leftover bits (`0 < b < 15`):
- `b > 7`: one more scalar from the table above for `(acc << (15 − b)) & 0x7FFF`.
- `1 ≤ b ≤ 7`: one scalar U+C040 + `((acc << (7 − b)) & 0x7F)`.

Decoding: scalars in the three ranges add 15 bits; a scalar in U+C040…U+C0BF adds 7 bits and is only allowed as the
**last** scalar; anything else fails. Emit a byte whenever ≥ 8 bits are buffered; leftover bits (< 8) are dropped.

## 3. Handshakes

`0x22` (Duhcord): `22 | flags | key(32)`. `flags` bit 0 = wantsReply ("I don't have your key yet").

`0x23` (Companion, new): `23 | flags | class | host | features(2) | key(32)` = 38 bytes.
- `flags` bit 0 = wantsReply. Other bits zero.
- `class`: `1` = Duhcord Private Companion. (Duhcord's own class is `0` and is never sent in a 0x23.)
- `host`: `1` Vencord, `2` Vesktop, `3` Replugged, `4` BetterDiscord, `0` unknown.
- `features` bit 0 text, bit 1 open images, bit 2 open single videos, bit 3 open reels, bit 8 send images, bit 9
  send videos. v1 companion sends `0x0003` (text + open images).
- `key`: raw X25519 public key.

A Companion reads a 0x22 handshake as class 0 with every feature. Duhcord builds that predate 0x23 ignore it (they
require exactly 34 bytes of type 0x22), so they never chat with a Companion.

**Label only weakens:** once a key has been seen in a 0x23 handshake, it stays class 1 even if a 0x22 with the same key
appears later.

### Handshake behaviour (mirrors `PrivateChatController.agree` / `scan`)
- *Agree* (user switches a DM to Private, or accepts a request): mark the peer consented; if this is the first consent
  or we hold no accepted key of theirs, send our handshake with `wantsReply = (we hold no accepted key of theirs)`.
- At most one of our handshakes per DM is in flight; it stops being in flight when Discord echoes it back (or the send
  fails).
- *Scan* each DM's loaded messages oldest→newest:
  - Our own handshake carrying a key that isn't ours → a candidate *own device* (pending, at most 4 pending).
  - The peer's handshake → learn the key (§6). If `wantsReply` and it's newer than our last handshake, there's an
    open request. If we already consented, answer automatically with `wantsReply = false`; otherwise show a request.
  - Handshakes from anyone else in the channel are ignored.

## 4. Encrypted message (`0x21`)

    21 | flags(1) | senderKeyID(4) | sentAt(4, Unix seconds) | salt(16) | n(1)
       | n × [ recipientKeyID(4) | enc(32) | wrapped(32) ]
       | ciphertext | tag(16)

- `fixedHeader = 27`, `entrySize = 68`, `headerEnd = 27 + 68n`. Reject if `n > 8` or length < `headerEnd + 16`.
- `keyID(pub) = SHA-256(pub)[0..4]`.
- `flags` bit 0: body was compressed; bit 1: body starts with a file list.

### Sealing
1. `raw` = (if files: `count(1) ‖ count × PrivateFile(45)`) ‖ UTF-8 text. Reject if `raw` > 65536 bytes, or > 4 files.
2. `compressed` = raw DEFLATE (RFC 1951, no zlib header — Apple `COMPRESSION_ZLIB`) of `raw`, used only if `raw` > 16
   bytes **and** the output is strictly shorter than `raw`. Otherwise send `raw` uncompressed.
3. `salt` = 16 random bytes. `messageKey = HKDF-SHA256(ikm = sender private key (32 raw bytes), salt = salt,
   info = "duhcord-message-key-v2/<channelID>", L = 32)`. `<channelID>` is the decimal snowflake string.
4. Recipients: de-duplicated public keys excluding the sender's own; 1…8 of them, else error (never drop one silently).
5. For each recipient, HPKE (RFC 9180) **auth mode**, suite DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
   ChaCha20-Poly1305 (`0x0020/0x0001/0x0003`), `info = "duhcord-private-v2/<channelID>"`, sender auth key = sender
   private key. `mask = Export("duhcord-message-key", 32)`. Entry = `keyID(recipient) ‖ enc ‖ (messageKey XOR mask)`.
6. `pad(x)` = `len(x) as UInt16 BE ‖ x ‖ zeros` up to a multiple of 128 bytes (including the 2 length bytes).
7. `ciphertext ‖ tag = ChaCha20-Poly1305(key = messageKey, nonce = 12 zero bytes, aad = header bytes [0, headerEnd),
   plaintext = pad(compressed or raw))`. The key is never reused, so the zero nonce is safe.
8. Content = §1 with this frame; reject if > 2000 UTF-16 units.

### Opening (recipient private key `R`, candidate sender public keys `S[]`, `fromSelf`)
- Candidate message keys:
  - If `fromSelf` and `senderKeyID == keyID(R.pub)`: `messageKey(R, salt, channelID)`.
  - If an entry has `recipientKeyID == keyID(R.pub)` (first such entry): for every `s ∈ S` with
    `keyID(s) == senderKeyID`, HPKE auth-mode receiver with `enc`, `info`, sender `s`; key = `wrapped XOR Export(...)`.
    Failures are skipped.
- The first candidate that opens the box wins. Then `unpad` (fail if declared length > available), decompress with raw
  INFLATE if flag bit 0 (fail if output > 65536 bytes or invalid), parse the file list if flag bit 1 (count 1…4, each
  `PrivateFile` valid), and the rest must be valid UTF-8.
- Result: text, `sentAt`, `salt`, files.

## 5. Files (`PrivateFile`, 45 bytes, inside the encrypted body)

    key(32) | length(4) | sealedLength(4) | width(2) | height(2) | kind(1)

- `kind`: 1 JPEG, 2 PNG, 3 MP4, 4 reel chunk. Valid only if `width > 0`, `height > 0`, `length ≤ 50 MiB`,
  `sealedLength == padme(length) + 16`.
- The attachment at the same position (Discord filename `encrypted.bin`) is
  `ChaCha20-Poly1305(key, nonce = 12 zero bytes, aad = "duhcord-file-v1", plaintext = file ‖ zeros up to padme(length))`.
  Its byte length must equal `sealedLength`, else it isn't this file.
- `padme(L)`: L ≤ 1 → max(L, 1); else `E = floor(log2 L)`, `S = floor(log2 E) + 1`, `mask = 2^(E−S) − 1`,
  result `(L + mask) & ~mask`.
- Text starting with `\u{1E}film/` or `\u{1E}reel/` describes a split video (see the Swift `PrivateFilmNote` /
  `PrivateReelNote`). Companion v1 doesn't play these; it shows "A private video — open it in Duhcord".

## 6. Trust (mirrors `PrivateChatController`)
- Per Discord account: one X25519 key pair, plus a directory of people → keys with trust `accepted | pending | rejected`,
  own devices (same trust values, up to 3 approved), consented peers, which DMs are in Private, and verification hashes.
- Learning a peer key: ignore it if invalid or already known. A peer's **first** key is `accepted` (trust on first use)
  — **except class-1 keys on Duhcord, which always start `pending`** (Duhcord-side rule). At most 4 pending per person;
  any more are ignored.
- Seal to the peer's accepted keys + our own key + our approved devices. Pending/rejected keys get nothing.
- Open with trusted senders first (peer's accepted keys; for our own messages, our key + approved devices). If that
  fails, try pending keys and add a warning line ("Sent from a new key you haven't accepted…"). Messages from
  rejected keys aren't shown.
- Replay: remember the first message ID for each salt. A later message with the same salt gets "A copy of an earlier
  private message"; if `|postedAt − sentAt| > 10 min` it gets "Written <time>, not when it appeared". `postedAt` is the
  edit time if edited, otherwise the snowflake time `((id >> 22) + 1420070400000) ms`.

## 7. Safety numbers and key codes
- `digits(input, groups)`: `h = SHA-512(input)`, `bytes = h ‖ SHA-512(h)`. Group `g` = the 5 bytes
  `bytes[5g..5g+5]` read as a big-endian integer, mod 100000, zero-padded to 5 digits; groups joined by a space.
- **v2** (every key on both sides is class 0): `side(keys)` = `count(unique keys) as UInt8 (clamped) ‖ unique keys
  sorted lexicographically`. With `first`/`second` the lexicographically smaller/larger side, input =
  `"duhcord-safety-number-v2" ‖ first ‖ second`. 12 groups.
- **v3** (any key on either side is class 1): `side(keys)` = `count as UInt8 ‖ for each unique key, sorted by key
  bytes: key(32) ‖ class(1)`. Input = `"duhcord-safety-number-v3" ‖ first ‖ second`. 12 groups. Because the class is
  included, Discord rewriting a 0x23 into a 0x22 makes the two sides' numbers differ.
- Key code: `digits("duhcord-key-code-v1" ‖ key, 6)`.
