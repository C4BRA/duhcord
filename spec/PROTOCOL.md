# Duhcord Private messaging — wire protocol v3

This file is the contract between the two clients that speak it: **Duhcord** (Swift, `Sources/DuhcordCore/PrivateMessaging.swift`,
`Sources/Duhcord/PrivateChatController.swift`) and the **Duhcord Private Companion** (Rust, `companion/crates/protocol`,
`companion/crates/engine`). Both implement it exactly. **This file is the authority**: if an implementation and this file
disagree, the implementation is wrong. Disagreements are caught by the shared byte vectors ([VECTORS.md](VECTORS.md)) and
behaviour scenarios ([SCENARIOS.md](SCENARIOS.md)), which both CIs run.

Everything here is byte-exact; all integers are big-endian. "Client" means either app; rules that apply to only one of
them say so.

v3 is a clean break: v2 content (`dhc2:`) is plain text to a v3 client, and nothing from v2 is migrated (see §10).

## 1. Message content

Every private-mode Discord message is exactly:

    -# encrypted messaging by C4BRA/duhcord 🤫\n
    dhc3:<DenseText(frame)>

Readers look only at the **last line** (text after the last `\n`, or the whole content when there is no `\n`). It must
start with `dhc3:`; the rest must DenseText-decode (§2), else the message is plain. The first byte of the decoded frame
is its type:

| type | meaning | size rule |
|---|---|---|
| `0x31` | encrypted message (§4) | ≥ 27 + 68 + 16 = 111 bytes (at least one recipient), see §4 |
| `0x32` | handshake (§3) | exactly `40 + 4·n` bytes for its `n` (0…8), otherwise plain |
| anything else | plain | |

Content must be ≤ 2000 UTF-16 code units (Discord's limit, counted like JavaScript `String.length`). A client never
sends content that breaks this rule; the bridge (BRIDGE.md) refuses to pass any content that isn't a `0x31` or `0x32`
frame.

## 2. DenseText (15 bits per UTF-16 unit)

Unchanged from v2. Bits are taken MSB-first from the bytes. Each full 15-bit group `v` becomes one scalar:

- `0 ≤ v < 6592` → U+3400 + v
- `6592 ≤ v < 27584` → U+4E00 + (v − 6592)
- `27584 ≤ v < 32768` → U+AC00 + (v − 27584)

At the end, with `b` leftover bits (`0 < b < 15`):
- `b > 7`: one more scalar from the table above for `(acc << (15 − b)) & 0x7FFF`.
- `1 ≤ b ≤ 7`: one scalar U+C040 + `((acc << (7 − b)) & 0x7F)`.

Decoding: scalars in the three ranges add 15 bits; a scalar in U+C040…U+C0BF adds 7 bits and is only allowed as the
**last** scalar; anything else fails. Emit a byte whenever ≥ 8 bits are buffered; leftover bits (< 8) are dropped.

## 3. Handshake (`0x32`)

One format for both clients:

    32 | flags(1) | version(1) | client(1) | host(1) | features(2) | key(32) | n(1) | n × acceptedKeyID(4)

Length = `40 + 4·n`, with `0 ≤ n ≤ 8` (type 1, flags 1, version 1, client 1, host 1, features 2, key 32, n 1).

| field | meaning |
|---|---|
| `flags` | bit 0 `wantsReply`: "answer with your handshake". Other bits zero; a handshake with other bits set is plain. |
| `version` | Protocol version, `3`. See "Versions" below. |
| `client` | `0` Duhcord, `1` Duhcord Private Companion. Anything else: plain. |
| `host` | Where the client runs. Duhcord: `0`. Companion: `1` Vencord, `2` Vesktop, `3` Replugged, `4` BetterDiscord, `5` Dorion, `0` unknown. Shown in the UI only; never used for trust. |
| `features` | What the sender's client can do with files: bit 0 text, bit 1 open images, bit 2 open single videos, bit 3 open reels, bit 8 send images, bit 9 send videos. Duhcord sends `0x030F`; Companion v1 `0x0003`. |
| `key` | The sender's raw X25519 public key. |
| `acceptedKeyID` | `keyID(k)` (§4) for each key `k` **of the person this handshake is sent to** that the sender currently counts (§6) — the receiver's proof that its key arrived and was accepted. Sorted ascending, no duplicates. |

### Versions
- A handshake whose `version` is higher than the reader's is not learned from. The reader's UI says the other person
  uses a newer version and that updating is needed to chat privately; the bridge status is `outdated` (BRIDGE.md).
- A handshake whose `version` is lower than 3 cannot be represented (v2 used other prefixes and types).
- Every later version keeps the first 7 bytes of this layout (`type` … `features`) so a reader can always tell what to
  show. Fields added later go after `acceptedKeyID` and change the length rule.

### When a client sends its handshake (per DM)
A client sends at most one handshake per DM at a time ("in flight" until Discord echoes it back in that DM, or the send
fails). It sends one when:

1. **Agree** — the user switches the DM to Private, or accepts a request — and it has not yet sent a handshake in this
   DM since this key was created, or it counts no key of the other person's: `wantsReply = (it counts none of theirs)`.
2. **Answer** — a handshake from the other person with `wantsReply = 1` is newer than this client's last handshake in
   the DM, and the user has agreed (consent, §6): `wantsReply = 0`. Without consent, it shows a request instead.
3. **Acceptance changed** — the set of the other person's keys this client counts (§6) changed while the DM is in
   Private, for any reason: the user accepted or rejected a key, a key was trusted on first use, a known key was
   relabelled, or the Companion exclusion or Duhcord's Companion setting changed: `wantsReply = 0`. This tells the other
   side what it can now rely on. (Without the first-use case, two people meeting for the first time would leave one of
   them `unconfirmed`.) When an answer (rule 2) and an acceptance change happen together, one handshake covers both.
4. **Re-send** — the user asks for it explicitly ("Re-send my key"): `wantsReply = 1`. The other side, if it consented,
   answers by rule 2. This is the recovery path for any confusion; both clients offer it in the DM's Private UI. A
   re-send always goes out, even if an earlier handshake is still in flight (Discord may have lost that one).

A handshake that's due while another is in flight is sent once that one is echoed (its `wantsReply` is the OR of
everything that was due).

A handshake always carries the sender's current `acceptedKeyID` list for the recipient.

### Reading handshakes
Each DM's loaded messages are read oldest → newest. A handshake whose author is neither the user nor the other person in
the DM is ignored. Group DMs and server channels are never private.

- **The other person's handshake**: learn its key (§6) with its `client` and `features`; record its `acceptedKeyID`
  list as the latest receipt (§6) if it's newer than the last one recorded; note a request if `wantsReply` and it's
  newer than our last handshake in the DM.
- **Our own handshake** (author is the user) with our current key: it's our last handshake in this DM; it's no longer in
  flight.
- **Our own handshake with another key**: a candidate own device (§7).

## 4. Encrypted message (`0x31`)

Unchanged from v2 except the type byte:

    31 | flags(1) | senderKeyID(4) | sentAt(4, Unix seconds) | salt(16) | n(1)
       | n × [ recipientKeyID(4) | enc(32) | wrapped(32) ]
       | ciphertext | tag(16)

- `fixedHeader = 27`, `entrySize = 68`, `headerEnd = 27 + 68n`. Reject if `n = 0`, `n > 8` or length < `headerEnd + 16`.
- `keyID(pub) = SHA-256(pub)[0..4]`.
- `flags` bit 0: body was compressed; bit 1: body starts with a file list. Other bits zero, else reject.
- The type byte is inside the authenticated header, so a v2 message can't be relabelled as v3.

### Sealing
1. `raw` = (if files: `count(1) ‖ count × PrivateFile(45)`) ‖ UTF-8 text. Reject if `raw` > 65536 bytes, or > 4 files.
2. `compressed` = raw DEFLATE (RFC 1951, no zlib header — Apple `COMPRESSION_ZLIB`) of `raw`, used only if `raw` > 16
   bytes **and** the output is strictly shorter than `raw`. Otherwise send `raw` uncompressed.
3. `salt` = 16 random bytes. `messageKey = HKDF-SHA256(ikm = sender private key (32 raw bytes), salt = salt,
   info = "duhcord-message-key-v2/<channelID>", L = 32)`. `<channelID>` is the decimal snowflake string.
4. Recipients: the keys §6 says receive the message, de-duplicated, excluding the sender's own; 1…8 of them, else
   refuse to send and say why (never drop one silently).
5. For each recipient, HPKE (RFC 9180) **auth mode**, suite DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 /
   ChaCha20-Poly1305 (`0x0020/0x0001/0x0003`), `info = "duhcord-private-v2/<channelID>"`, sender auth key = sender
   private key. `mask = Export("duhcord-message-key", 32)`. Entry = `keyID(recipient) ‖ enc ‖ (messageKey XOR mask)`.
6. `pad(x)` = `len(x) as UInt16 BE ‖ x ‖ zeros` up to a multiple of 128 bytes (including the 2 length bytes).
7. `ciphertext ‖ tag = ChaCha20-Poly1305(key = messageKey, nonce = 12 zero bytes, aad = header bytes [0, headerEnd),
   plaintext = pad(compressed or raw))`. The key is never reused, so the zero nonce is safe.
8. Content = §1 with this frame; refuse to send if > 2000 UTF-16 units.

(The HKDF/HPKE labels keep their `-v2` names: they're unchanged, and the type byte already separates the versions.)

### Opening (recipient private key `R`, candidate sender public keys `S[]`, `fromSelf`)
- Candidate message keys:
  - If `fromSelf` and `senderKeyID == keyID(R.pub)`: `messageKey(R, salt, channelID)`.
  - If an entry has `recipientKeyID == keyID(R.pub)` (first such entry): for every `s ∈ S` with
    `keyID(s) == senderKeyID`, HPKE auth-mode receiver with `enc`, `info`, sender `s`; key = `wrapped XOR Export(...)`.
    Failures are skipped.
- The first candidate that opens the box wins. Then `unpad` (fail if declared length > available), decompress with raw
  INFLATE if flag bit 0 (fail if output > 65536 bytes or invalid), parse the file list if flag bit 1 (count 1…4, each
  `PrivateFile` valid), and the rest must be valid UTF-8.
- Result: text, `sentAt`, `salt`, files, and the list of `recipientKeyID`s (used as a receipt, §6).

## 5. Files (`PrivateFile`, 45 bytes, inside the encrypted body)

Unchanged from v2.

    key(32) | length(4) | sealedLength(4) | width(2) | height(2) | kind(1)

- `kind`: 1 JPEG, 2 PNG, 3 MP4, 4 reel chunk. Valid only if `width > 0`, `height > 0`, `length ≤ 50 MiB`,
  `sealedLength == padme(length) + 16`.
- The attachment at the same position (Discord filename `encrypted.bin`) is
  `ChaCha20-Poly1305(key, nonce = 12 zero bytes, aad = "duhcord-file-v1", plaintext = file ‖ zeros up to padme(length))`.
  Its byte length must equal `sealedLength`, else it isn't this file. Downloads only from `cdn.discordapp.com` or
  `media.discordapp.net` over HTTPS.
- `padme(L)`: L ≤ 1 → max(L, 1); else `E = floor(log2 L)`, `S = floor(log2 E) + 1`, `mask = 2^(E−S) − 1`,
  result `(L + mask) & ~mask`.
- Text starting with `\u{1E}film/` or `\u{1E}reel/` describes a split video (see the Swift `PrivateFilmNote` /
  `PrivateReelNote`). A client without the matching `features` bit shows "A private video — open it in Duhcord".
- **Feature gating**: a client only sends a file kind if every recipient key of the other person has the matching
  "open" bit; otherwise attaching is disabled with the reason.

## 6. Trust, consent and status (identical in both clients)

### State per Discord account
One X25519 key pair; a directory of people → keys (each with `client`, `features`, trust `accepted | pending |
rejected`, when it was added); own devices (§7); consented people; which DMs are in Private; verification
fingerprints; for each person, the latest **receipt** (the `acceptedKeyID` set from their newest handshake, plus key IDs
seen in their messages, both only for our *current* key); and the Companion exclusion set.

### Learning a key from the other person's handshake
- Ignore it if the key is invalid (non-contributory X25519) or its `version` is too new (§3).
- **New key:**
  - `client = 0` (Duhcord) and it's the person's **first** key: `accepted` (trust on first use).
  - Otherwise — any later key, and **every** `client = 1` (Companion) key, first or not — `pending`. At most 4
    pending per person; any more are ignored.
- **Known `client = 0` key, now `client = 1`:** the key becomes a Companion key and, if it was `accepted`, `pending`
  again (a Companion key needs its own approval). The verification is cleared.
- **Known `client = 1` key, now `client = 0`:** nothing changes. A key never gains Duhcord's label, and demoting it
  again would let Discord force endless re-approvals.
- Known key, same `client`: update its `features`.

### Which keys count
A key of the other person **counts** if it's `accepted` and not excluded. A key is excluded when it's `client = 1` and
either the user excluded Companion keys for this person, or (Duhcord only) the setting "Private chat with Duhcord
Companion" is off. Excluded keys behave as if they weren't accepted: they get no messages, don't appear in the safety
number, and don't make the DM ready.

### Receipts — "they have my key"
The other person **has our key** if our current key's ID is in their latest handshake's `acceptedKeyID` list, or a
message from them that opened with a counted sender key has our key's ID among its recipients. A later handshake whose
list lacks our ID clears it (they rejected or excluded us).

### Status of a DM (the same states in both clients and on the bridge)
| state | when | composer |
|---|---|---|
| `off` | not in Private | — |
| `request` | the other person asked and the user hasn't agreed | — |
| `waiting` | in Private, no key of theirs counts yet | disabled |
| `unconfirmed` | a key of theirs counts, but they don't have our key yet (no receipt) | disabled (§11, decision 2); "Re-send my key" offered |
| `ready` | a key of theirs counts **and** they have our key | enabled |
| `outdated` | their newest handshake's `version` is higher than ours | disabled; "update to chat privately" |
| `locked` | our key store is unavailable | disabled |

Two flags go with `waiting`/`unconfirmed`/`ready`: `newKey` (a key of theirs is pending) and `verified` (§8).

### Sending and opening
- Seal to: the other person's counted keys + our own key + our approved own devices (§7). Pending, rejected and
  excluded keys get nothing.
- Open with counted senders first (their counted keys; for our own messages, our key and approved devices). If that
  fails, try their pending keys and add the warning "Sent from a new key you haven't accepted. It may not be them."
  (own pending device: "Sent from a device you haven't approved."). Messages from rejected or excluded keys aren't
  shown.
- Replay: remember the first message ID for each salt. A later message with the same salt gets "A copy of an earlier
  private message. Discord may have resent it."; otherwise, if `|postedAt − sentAt| > 10 min`, it gets "Written <time>,
  not when it appeared". `postedAt` is the edit time if edited, else the snowflake time
  `((id >> 22) + 1420070400000) ms`.

### Accepting and rejecting
- Accepting covers exactly the pending keys that were shown, with the safety number shown. If the user typed or
  confirmed a compared number, it must equal the number shown with those keys, else nothing changes. Accepting with a
  compared number also marks the DM verified (§8).
- Rejected keys stay rejected for good.
- After either, the client sends a handshake (§3 rule 3).

## 7. Own devices

A user may run more than one client on one Discord account (several Macs, a Mac and a PC with the Companion). Each
install has its own key.

- Our own handshake (author is the user) with a key that isn't ours and isn't known is a **candidate device**:
  `pending`, at most 4 pending. Its `client` is recorded.
- Approved (`accepted`) devices receive everything we send, and their messages open as ours. At most **3** others may
  be approved.
- Each device's key is listed with its key code (§8) and client, so the user can compare it with what that device shows
  as its own code.
- A device of either client may be approved: a Duhcord user can approve their Companion, and a Companion user their
  Macs. A Companion device is labelled as such wherever devices are listed, and counted with `client = 1` in the
  safety number (§11, decision 1).

## 8. Safety numbers and key codes

One formula in both clients, always including each key's client:

- `digits(input, groups)`: `h = SHA-512(input)`, `bytes = h ‖ SHA-512(h)`. Group `g` = the 5 bytes
  `bytes[5g..5g+5]` read as a big-endian integer, mod 100000, zero-padded to 5 digits; groups joined by a space.
- `side(keys)` = `count(unique keys) as UInt8 ‖ for each unique key, sorted by key bytes: key(32) ‖ client(1)`.
- Our side: our key and our approved devices; their side: their counted keys. With `first`/`second` the
  lexicographically smaller/larger side, the number is `digits("duhcord-safety-number-v3" ‖ first ‖ second, 12)`.
- Both clients show, next to the number, the key code of every key on each side, labelled with its client. A mismatch
  then shows which key differs.
- Key code: `digits("duhcord-key-code-v1" ‖ key, 6)`.
- **Verified**: the user compared the number; the client stores `SHA-256(number)` for the person. The DM is verified
  while the current number hashes to it. Any key change on either side changes the number, so it stops being verified.

## 9. What Discord can still do

Discord carries every message, so it can drop, delay, reorder or replay them, and substitute keys in handshakes. The
protocol makes those visible rather than impossible: replays and delays get warnings (§6), new keys wait for approval,
and a substituted or relabelled key changes the safety number. It never sees a private key or plaintext.

## 10. Changes from v2 (clean break)

- Prefix `dhc2:` → `dhc3:`; message type `0x21` → `0x31`; the two handshakes `0x22` (Duhcord) and `0x23` (Companion)
  → one `0x32` with `version`, `client`, `host`, `features` and the `acceptedKeyID` receipt list.
- Receipts (§6): a DM is `ready` only when the other person has demonstrably accepted our key; new state
  `unconfirmed`. Previously a client showed Private as soon as it had *their* key.
- The "Re-send my key" handshake (§3 rule 4) and the acceptance-changed handshake (rule 3).
- One trust rule for both clients: a Companion key is never trusted on first use, on either client.
- One safety-number formula (always with the client byte); the v2 formula is gone. Key codes for both sides are shown
  next to it.
- Versions: a too-new handshake shows `outdated` instead of being silently ignored.
- No migration: v2 messages read as plain text, v2 directories are discarded, and keys are regenerated.

## 11. Decisions

1. **A Companion may be one of a Duhcord user's own devices** (and Macs may be a Companion user's devices). Only after
   approval, labelled "Companion", and counted with its client in the safety number, the same rule as for a Mac. (v2
   Duhcord ignored its own Companion handshakes.)
2. **`unconfirmed` blocks sending.** Messages sent before the other side accepted our key can't be opened as trusted by
   them until they do, which looks broken.
3. **"Private chat with Duhcord Companion" stays off by default in Duhcord.** With receipts, a Companion user sees
   `unconfirmed` while it's off, instead of a chat that looks ready.
