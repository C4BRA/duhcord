# Behaviour scenarios (protocol v3)

[VECTORS.md](VECTORS.md) proves Duhcord and the Companion encode and decode identically. This file makes sure they also
**decide** identically: when to send a handshake, which keys they trust, what state a DM is in, and what the safety
number is. Each scenario is a JSON file in `spec/scenarios/`. Both clients run every file with a runner that drives
**their real trust code** (not a re-implementation), and every expectation must hold at every step. A scenario that
fails on one side and passes on the other is a bug in that side, or in this spec.

## The simulated DM

- One DM channel, `channelId = "1100000000000000001"`, between two people: `alice` (user ID `1001`) and `bob` (user ID
  `1002`).
- Each scenario declares **devices**: one install of a client for one person, e.g. `alice-mac` (Duhcord, alice),
  `bob-pc` (Companion on BetterDiscord, bob). A device's private key is `SHA-256("duhcord-vector-<device name>")`.
- **Discord** is an ordered log of messages. A device never sees another device's state, only the log.
  - What a device sends goes to its **outbox**. `deliver` appends every outbox message to the log in the order they
    were sent, each with the next snowflake ID, author = the device's person.
  - After every step, every device reads the whole log (as if Discord loaded the DM), so a device sees its own messages
    echoed back exactly as on Discord.
  - Snowflake times start at `sentAt = 1700000000` and advance 1 s per message, so replay-time warnings only fire when a
    scenario asks for them.
- Settings start at defaults: Private off in the DM, Duhcord's "Private chat with Duhcord Companion" **on** unless a
  scenario turns it off.

## File format

```json
{
  "name": "duhcord-and-companion-first-contact",
  "description": "What this checks, in a sentence.",
  "devices": {
    "alice-mac": { "person": "alice", "client": "duhcord" },
    "bob-pc": { "person": "bob", "client": "companion", "host": "betterdiscord" }
  },
  "steps": [
    { "do": "setPrivate", "device": "alice-mac", "on": true },
    { "do": "deliver" },
    { "expect": {
        "alice-mac": { "state": "waiting" },
        "bob-pc": { "state": "request" }
    } }
  ]
}
```

### Actions (`do`)
| action | fields | meaning |
|---|---|---|
| `setPrivate` | `device`, `on` | The user switches the DM to Private (`on: true`, which also agrees to a request) or back to standard. |
| `resendKey` | `device` | "Re-send my key" (PROTOCOL.md §3 rule 4). |
| `accept` | `device`, `keys` (device names), `compared` (`"shown"`, a 60-digit string, or absent) | Accept those pending keys. `"shown"` means the user confirms the number shown with them. |
| `reject` | `device`, `keys` | Reject those pending keys. |
| `markVerified` | `device` | The user confirms the current safety number. |
| `excludeCompanion` | `device`, `on` | The per-person Companion exclusion. |
| `allowCompanionChat` | `device`, `on` | Duhcord's setting. Companion devices ignore it. |
| `setDevice` | `device`, `key` (device name), `trust` (`accepted` / `rejected`) | Approve or deny one of the user's own other devices. |
| `send` | `device`, `text` | The user sends a private message. Expect `sendRefused` if it must not be sent. |
| `deliver` | — | Discord delivers every outbox. |
| `drop` | `device` | Discord silently drops everything in that device's outbox. |
| `relabel` | `device`, `client` (0 or 1) | Discord rewrites the `client` byte of the handshakes in that device's outbox. |
| `replay` | `index` (log position, negative from the end) | Discord posts a copy of that log message again. |
| `inject` | `person`, `handshake` (`key` = any device name, `wantsReply`, `client`, `host`, `features`, `acceptedKeys` = device names, `version`) | Discord posts a handshake as that person, e.g. one with `version: 4`. The key name needn't be a declared device. |
| `delay` | `seconds` | The next delivered messages get snowflake times that much later. |

### Expectations (`expect`)
Per device, any of:

| field | value |
|---|---|
| `state` | `off`, `request`, `waiting`, `unconfirmed`, `ready`, `outdated`, `locked` (PROTOCOL.md §6). |
| `newKey`, `verified` | booleans. |
| `canSend` | boolean: the composer is enabled. |
| `keys` | map of device name → `accepted` / `pending` / `rejected` / `excluded` / `unknown` for the **other** person's keys. |
| `devices` | map of device name → `accepted` / `pending` / `rejected` / `unknown` for **our own** other devices. |
| `hasOurKey` | boolean: the receipt (§6) says the other person has accepted this device's key. |
| `outbox` | list, in order, of what the device has queued and Discord hasn't delivered yet: `"message"`, `"handshake"`, or `{ "handshake": { "wantsReply": …, "acceptedKeys": [device names] } }` (fields present are checked; `acceptedKeys` in any order). |
| `messages` | the private messages this device shows, oldest first: `{ "from": device, "text": …, "warnings": [codes] }`. Warning codes: `untrusted-sender`, `unapproved-device`, `copy`, `written-earlier`. |
| `sendRefused` | the last `send` was refused, with a reason code: `not-ready`, `too-many-recipients`. |
| `safetyNumber` | `{ "same-as": "<other device>" }`, `{ "differs-from": "<other device>" }`, or `{ "none": "" }` (no key of theirs counts). |

## Required scenarios

Each is one file in `spec/scenarios/`; both CIs fail if any file is missing or failing.

1. **duhcord-pair**: two Duhcord devices. Request → agree → both `ready`; first keys trusted on first use; messages both
   ways; same safety number.
2. **duhcord-and-companion**: alice Duhcord, bob Companion. Bob's key arrives `pending` on alice even though it's his
   first. Bob sees `unconfirmed` until alice accepts (her acceptance handshake lists his key), then both `ready`, same
   safety number, messages both ways.
3. **companion-chat-off**: as 2 with alice's setting off: bob stays `unconfirmed`, alice never sends to bob's key;
   turning it on and accepting makes both `ready`.
4. **dropped-handshake**: Discord drops alice's first handshake. Both stay stuck until `resendKey`, then `ready`.
5. **relabel-first-handshake**: Discord rewrites bob's Companion handshake as Duhcord. Alice trusts it on first use as a
   Duhcord key, so the safety numbers **differ** between alice and bob — the attack is visible when they compare.
6. **relabel-known-key**: a known Duhcord key later appears as Companion: it becomes Companion and `pending`, alice's
   `verified` is cleared, she stops sending to it, and a message bob sent before hearing about it shows
   `untrusted-sender`. A later Duhcord claim for the same key changes nothing. Re-accepting makes her ready; the
   safety numbers stay different (the relabelling stays visible).
7. **new-key**: bob adds an install (a new key, same person). It's `pending` on alice and that install is
   `unconfirmed`; accepting with a wrong number changes nothing; accepting with the shown number makes alice
   `verified`; once bob's two installs approve each other, all three safety numbers match.
8. **reject**: alice rejects bob's new key: her next handshake no longer lists it, so that install sees
   `hasOurKey: false` (`unconfirmed`), and her messages go only to bob's accepted key.
9. **own-devices**: alice (Duhcord) adds a second device, a Companion. It's `pending` in her Mac's `devices` until
   approved; then messages to bob are sealed to it, its messages open as alice's own, and both sides' safety numbers
   change (and match, with the device counted as a Companion key).
10. **exclude-companion**: alice excludes bob's Companion keys: bob becomes `unconfirmed`, alice's safety number drops
    them; turning the exclusion off restores `ready`.
11. **replay-and-delay**: a replayed copy shows `copy`; a message delivered 11 minutes after it was written shows
    `written-earlier`.
12. **outdated**: an injected `version: 4` handshake from bob makes alice `outdated`, with sending disabled; her
    directory doesn't learn its key.
13. **pending-limit**: five new keys for bob: four are `pending`, the fifth is `unknown`.
14. **too-many-recipients**: enough approved keys that a message would need more than 8 recipients: `send` is refused
    with `too-many-recipients`, nothing is queued.

## Runners

- **Companion** (Rust): `companion/crates/engine/tests/scenarios.rs` drives one `Engine` per device, configured as a
  Duhcord or a Companion device as the scenario says. `SCENARIO=<name> cargo test -p duhcord-companion-engine` runs one.
- **Duhcord** (Swift): `Tests/DuhcordCoreTests/PrivateScenarioTests.swift` drives `PrivateTrustEngine` (in
  `DuhcordCore`, the code `PrivateChatController` runs) per device, configured the same way.
- Both runners read the files from `spec/scenarios/` directly; nothing is copied.
