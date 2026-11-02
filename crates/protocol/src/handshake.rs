use crate::{dense_text, PublicKey, PREFIX};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum ClientClass {
    Duhcord = 0,
    Companion = 1,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Host {
    Unknown = 0,
    Vencord = 1,
    Vesktop = 2,
    Replugged = 3,
    BetterDiscord = 4,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
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
}

impl std::ops::BitOr for Features {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Handshake {
    pub key: PublicKey,
    pub wants_reply: bool,
    pub class: ClientClass,
    pub host: Host,
    pub features: Features,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Kind {
    Plain,
    Handshake(Handshake),
    Encrypted(Vec<u8>),
}

pub fn kind(content: &str) -> Kind {
    let last_line = content.rsplit('\n').next().unwrap_or(content);
    let Some(encoded) = last_line.strip_prefix(PREFIX) else {
        return Kind::Plain;
    };
    let Some(frame) = dense_text::decode(encoded) else {
        return Kind::Plain;
    };
    let Some(message_type) = frame.first().copied() else {
        return Kind::Plain;
    };

    match message_type {
        0x21 => Kind::Encrypted(frame),
        0x22 if frame.len() == 34 => {
            let mut key = [0u8; 32];
            key.copy_from_slice(&frame[2..34]);
            Kind::Handshake(Handshake {
                key,
                wants_reply: frame[1] & 1 != 0,
                class: ClientClass::Duhcord,
                host: Host::Unknown,
                features: Features::DUHCORD,
            })
        }
        0x23 if frame.len() == 38
            && frame[2] == ClientClass::Companion as u8
            && frame[1] & 0xfe == 0 =>
        {
            let host = match frame[3] {
                0 => Host::Unknown,
                1 => Host::Vencord,
                2 => Host::Vesktop,
                3 => Host::Replugged,
                4 => Host::BetterDiscord,
                _ => return Kind::Plain,
            };
            let features = u16::from_be_bytes([frame[4], frame[5]]);
            let mut key = [0u8; 32];
            key.copy_from_slice(&frame[6..38]);
            Kind::Handshake(Handshake {
                key,
                wants_reply: frame[1] & 1 != 0,
                class: ClientClass::Companion,
                host,
                features: Features(features),
            })
        }
        _ => Kind::Plain,
    }
}

pub fn handshake_content(handshake: &Handshake) -> String {
    let mut frame = match handshake.class {
        ClientClass::Duhcord => vec![0x22, u8::from(handshake.wants_reply)],
        ClientClass::Companion => vec![
            0x23,
            u8::from(handshake.wants_reply),
            ClientClass::Companion as u8,
            handshake.host as u8,
            (handshake.features.0 >> 8) as u8,
            handshake.features.0 as u8,
        ],
    };
    frame.extend_from_slice(&handshake.key);
    format!(
        "{}\n{}{}",
        crate::NOTICE,
        PREFIX,
        dense_text::encode(&frame)
    )
}
