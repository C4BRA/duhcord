//! Frame types and the v3 handshake (spec/PROTOCOL.md §1, §3).

use crate::{dense_text, PublicKey, MAX_RECIPIENTS, PREFIX};

/// The protocol version this implementation speaks.
pub const PROTOCOL_VERSION: u8 = 3;

pub(crate) const MESSAGE_TYPE: u8 = 0x31;
pub(crate) const HANDSHAKE_TYPE: u8 = 0x32;
/// type, flags, version, client, host, features(2), key(32), n.
const HANDSHAKE_FIXED: usize = 40;
/// The prefix every later version keeps: type, flags, version, client, host, features(2).
const HANDSHAKE_STABLE_PREFIX: usize = 7;
const MESSAGE_FIXED_HEADER: usize = 27;
const MESSAGE_ENTRY: usize = 68;
const TAG: usize = 16;
/// Most accepted key IDs one handshake carries.
pub const MAX_ACCEPTED_KEY_IDS: usize = 8;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum ClientClass {
    Duhcord = 0,
    Companion = 1,
}

impl ClientClass {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Duhcord),
            1 => Some(Self::Companion),
            _ => None,
        }
    }
}

/// Where a client runs (spec §3 `host`). Shown in the UI only; never used for trust. Kept as the raw byte so unknown
/// values round-trip.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct Host(pub u8);

impl Host {
    pub const UNKNOWN: Self = Self(0);
    pub const VENCORD: Self = Self(1);
    pub const VESKTOP: Self = Self(2);
    pub const REPLUGGED: Self = Self(3);
    pub const BETTERDISCORD: Self = Self(4);
    pub const DORION: Self = Self(5);
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Hash)]
pub struct Features(pub u16);

impl Features {
    pub const TEXT: Self = Self(0x001);
    pub const OPEN_IMAGES: Self = Self(0x002);
    pub const OPEN_VIDEO: Self = Self(0x004);
    pub const OPEN_REELS: Self = Self(0x008);
    pub const SEND_IMAGES: Self = Self(0x100);
    pub const SEND_VIDEO: Self = Self(0x200);
    pub const COMPANION_V1: Self = Self(Self::TEXT.0 | Self::OPEN_IMAGES.0);
    pub const DUHCORD: Self = Self(
        Self::TEXT.0
            | Self::OPEN_IMAGES.0
            | Self::OPEN_VIDEO.0
            | Self::OPEN_REELS.0
            | Self::SEND_IMAGES.0
            | Self::SEND_VIDEO.0,
    );

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl std::ops::BitOr for Features {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

/// A v3 handshake (spec §3).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Handshake {
    pub key: PublicKey,
    pub wants_reply: bool,
    pub class: ClientClass,
    pub host: Host,
    pub features: Features,
    /// `keyID`s of the recipient's keys the sender counts: proof that they arrived and were accepted.
    pub accepted_key_ids: Vec<[u8; 4]>,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Kind {
    Plain,
    Handshake(Handshake),
    /// A handshake from a newer protocol version: nothing in it is learned (spec §3 "Versions").
    NewerHandshake {
        version: u8,
    },
    /// A `0x31` frame whose shape is valid; opening it is a separate step.
    Encrypted(Vec<u8>),
}

/// Reads a Discord message's content (spec §1). Anything that isn't exactly a valid frame is `Plain`.
pub fn kind(content: &str) -> Kind {
    let last_line = content.rsplit('\n').next().unwrap_or(content);
    let Some(encoded) = last_line.strip_prefix(PREFIX) else {
        return Kind::Plain;
    };
    let Some(frame) = dense_text::decode(encoded) else {
        return Kind::Plain;
    };
    match frame.first().copied() {
        Some(MESSAGE_TYPE) if valid_message_shape(&frame) => Kind::Encrypted(frame),
        Some(HANDSHAKE_TYPE) => parse_handshake(&frame),
        _ => Kind::Plain,
    }
}

fn valid_message_shape(frame: &[u8]) -> bool {
    if frame.len() < MESSAGE_FIXED_HEADER || frame[1] & !0b11 != 0 {
        return false;
    }
    let count = usize::from(frame[MESSAGE_FIXED_HEADER - 1]);
    (1..=MAX_RECIPIENTS).contains(&count)
        && frame.len() >= MESSAGE_FIXED_HEADER + MESSAGE_ENTRY * count + TAG
}

fn parse_handshake(frame: &[u8]) -> Kind {
    if frame.len() < HANDSHAKE_STABLE_PREFIX {
        return Kind::Plain;
    }
    let version = frame[2];
    if version > PROTOCOL_VERSION {
        // Later versions keep the first 7 bytes; nothing else in them is understood.
        return Kind::NewerHandshake { version };
    }
    if version < PROTOCOL_VERSION || frame.len() < HANDSHAKE_FIXED || frame[1] & !1 != 0 {
        return Kind::Plain;
    }
    let Some(class) = ClientClass::from_byte(frame[3]) else {
        return Kind::Plain;
    };
    let count = usize::from(frame[HANDSHAKE_FIXED - 1]);
    if count > MAX_ACCEPTED_KEY_IDS || frame.len() != HANDSHAKE_FIXED + 4 * count {
        return Kind::Plain;
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&frame[7..39]);
    let mut accepted_key_ids: Vec<[u8; 4]> = frame[HANDSHAKE_FIXED..].as_chunks::<4>().0.to_vec();
    accepted_key_ids.sort_unstable();
    accepted_key_ids.dedup();
    Kind::Handshake(Handshake {
        key,
        wants_reply: frame[1] & 1 != 0,
        class,
        host: Host(frame[4]),
        features: Features(u16::from_be_bytes([frame[5], frame[6]])),
        accepted_key_ids,
    })
}

/// The frame bytes of a handshake. Accepted key IDs are sorted and de-duplicated; more than 8 is a caller bug.
pub fn handshake_frame(handshake: &Handshake) -> Vec<u8> {
    let mut ids = handshake.accepted_key_ids.clone();
    ids.sort_unstable();
    ids.dedup();
    assert!(
        ids.len() <= MAX_ACCEPTED_KEY_IDS,
        "a handshake carries at most {MAX_ACCEPTED_KEY_IDS} accepted key IDs"
    );
    let mut frame = Vec::with_capacity(HANDSHAKE_FIXED + 4 * ids.len());
    frame.push(HANDSHAKE_TYPE);
    frame.push(u8::from(handshake.wants_reply));
    frame.push(PROTOCOL_VERSION);
    frame.push(handshake.class as u8);
    frame.push(handshake.host.0);
    frame.extend_from_slice(&handshake.features.0.to_be_bytes());
    frame.extend_from_slice(&handshake.key);
    frame.push(ids.len() as u8);
    for id in ids {
        frame.extend_from_slice(&id);
    }
    frame
}

/// The full Discord message content of a handshake (spec §1).
pub fn handshake_content(handshake: &Handshake) -> String {
    frame_content(&handshake_frame(handshake))
}

/// Wraps any frame as message content: the notice line, then `dhc3:` and the DenseText.
pub fn frame_content(frame: &[u8]) -> String {
    format!("{}\n{}{}", crate::NOTICE, PREFIX, dense_text::encode(frame))
}
