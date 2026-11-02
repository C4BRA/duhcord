use std::io::{Read, Write};

use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    ChaCha20Poly1305, Nonce,
};
use flate2::{read::DeflateDecoder, write::DeflateEncoder, Compression};
use hkdf::Hkdf;
use hpke::{
    aead::ChaCha20Poly1305 as HpkeChaCha20Poly1305,
    kdf::HkdfSha256,
    kem::{Kem as HpkeKem, X25519HkdfSha256},
    Deserializable, OpModeR, OpModeS, Serializable,
};
use rand_core::TryRngCore;
use sha2::Sha256;
use thiserror::Error;
use zeroize::Zeroizing;

use crate::{
    dense_text, file::PrivateFile, key::PrivateKey, safety::key_id, PublicKey, MAX_CONTENT_UTF16,
    MAX_FILES, MAX_PLAINTEXT, MAX_RECIPIENTS, NOTICE, PREFIX,
};

const MESSAGE_TYPE: u8 = 0x21;
const FIXED_HEADER: usize = 27;
const ENTRY_SIZE: usize = 68;
const EXPORT_CONTEXT: &[u8] = b"duhcord-message-key";
const ZERO_NONCE: [u8; 12] = [0; 12];
type Kem = X25519HkdfSha256;

#[derive(Debug, Error, Clone, Copy, PartialEq, Eq)]
pub enum SealError {
    #[error("no recipients")]
    NoRecipients,
    #[error("too many recipients")]
    TooManyRecipients,
    #[error("too many files")]
    TooManyFiles,
    #[error("message is too long")]
    TooLong,
    #[error("cryptographic operation failed")]
    Crypto,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Opened {
    pub text: String,
    pub sent_at: u32,
    pub salt: [u8; 16],
    pub files: Vec<PrivateFile>,
}

pub fn seal(
    text: &str,
    files: &[PrivateFile],
    channel_id: u64,
    sender: &PrivateKey,
    recipients: &[PublicKey],
    now_unix: u32,
) -> Result<String, SealError> {
    unique_recipients(recipients, sender)?;
    if files.len() > MAX_FILES {
        return Err(SealError::TooManyFiles);
    }

    let mut raw = Vec::new();
    if !files.is_empty() {
        raw.push(files.len() as u8);
        for file in files {
            if !file.is_valid() {
                return Err(SealError::Crypto);
            }
            raw.extend_from_slice(&file.encode());
        }
    }
    raw.extend_from_slice(text.as_bytes());
    if raw.len() > MAX_PLAINTEXT {
        return Err(SealError::TooLong);
    }

    let compressed = compress(&raw)?;
    let (body, compressed_flag) = match compressed {
        Some(compressed) => (compressed, true),
        None => (raw, false),
    };
    let flags = u8::from(compressed_flag) | (u8::from(!files.is_empty()) << 1);
    let frame = seal_frame(&body, flags, channel_id, sender, recipients, now_unix)?;
    let content = format!("{NOTICE}\n{PREFIX}{}", dense_text::encode(&frame));
    if content.encode_utf16().count() > MAX_CONTENT_UTF16 {
        return Err(SealError::TooLong);
    }
    Ok(content)
}

pub fn open(
    payload: &[u8],
    channel_id: u64,
    recipient: &PrivateKey,
    senders: &[PublicKey],
    from_self: bool,
) -> Option<Opened> {
    if payload.len() <= FIXED_HEADER || payload.first().copied() != Some(MESSAGE_TYPE) {
        return None;
    }
    let flags = payload[1];
    let sender_id: [u8; 4] = payload[2..6].try_into().ok()?;
    let sent_at = u32::from_be_bytes(payload[6..10].try_into().ok()?);
    let salt: [u8; 16] = payload[10..26].try_into().ok()?;
    let count = usize::from(payload[26]);
    if count > MAX_RECIPIENTS {
        return None;
    }
    let header_end = FIXED_HEADER + ENTRY_SIZE * count;
    if payload.len() < header_end + 16 {
        return None;
    }

    let recipient_id = key_id(&recipient.public_key());
    let mut candidates = Vec::new();
    if from_self && sender_id == recipient_id {
        candidates.push(message_key(recipient, &salt, channel_id).ok()?);
    }

    let matching_entry = (0..count).find(|index| {
        let start = FIXED_HEADER + index * ENTRY_SIZE;
        payload[start..start + 4] == recipient_id
    });
    if let Some(index) = matching_entry {
        let start = FIXED_HEADER + index * ENTRY_SIZE;
        if let Ok(encapped_key) =
            <Kem as HpkeKem>::EncappedKey::from_bytes(&payload[start + 4..start + 36])
        {
            for sender in senders.iter().filter(|sender| key_id(sender) == sender_id) {
                if let Some(candidate) = recipient_message_key(
                    recipient,
                    sender,
                    &encapped_key,
                    &payload[start + 36..start + ENTRY_SIZE],
                    channel_id,
                ) {
                    candidates.push(candidate);
                }
            }
        }
    }

    let cipher_text = &payload[header_end..];
    let mut plaintext = None;
    for candidate in candidates {
        let cipher = ChaCha20Poly1305::new_from_slice(&candidate[..]).ok()?;
        if let Ok(decrypted) = cipher.decrypt(
            Nonce::from_slice(&ZERO_NONCE),
            Payload {
                msg: cipher_text,
                aad: &payload[..header_end],
            },
        ) {
            plaintext = Some(decrypted);
            break;
        }
    }
    let unpadded = unpad(&plaintext?)?;
    let mut body = if flags & 1 != 0 {
        decompress(&unpadded)?
    } else {
        unpadded
    };

    let mut files = Vec::new();
    if flags & 2 != 0 {
        let file_count = usize::from(*body.first()?);
        if !(1..=MAX_FILES).contains(&file_count) || body.len() < 1 + file_count * 45 {
            return None;
        }
        for index in 0..file_count {
            let start = 1 + index * 45;
            files.push(PrivateFile::decode(&body[start..start + 45])?);
        }
        body.drain(..1 + file_count * 45);
    }
    let text = String::from_utf8(body).ok()?;
    Some(Opened {
        text,
        sent_at,
        salt,
        files,
    })
}

fn seal_frame(
    body: &[u8],
    flags: u8,
    channel_id: u64,
    sender: &PrivateKey,
    recipients: &[PublicKey],
    now_unix: u32,
) -> Result<Vec<u8>, SealError> {
    let unique = unique_recipients(recipients, sender)?;
    let own_key = sender.public_key();
    if body.len() > MAX_PLAINTEXT {
        return Err(SealError::TooLong);
    }

    let mut salt = [0u8; 16];
    rand_core::OsRng
        .try_fill_bytes(&mut salt)
        .map_err(|_| SealError::Crypto)?;
    let message_key = message_key(sender, &salt, channel_id)?;
    let sender_bytes = sender.to_bytes();
    let hpke_sender_public =
        <Kem as HpkeKem>::PublicKey::from_bytes(&own_key[..]).map_err(|_| SealError::Crypto)?;
    let info = format!("duhcord-private-v2/{channel_id}");

    let mut header = Vec::with_capacity(FIXED_HEADER + ENTRY_SIZE * unique.len());
    header.push(MESSAGE_TYPE);
    header.push(flags);
    header.extend_from_slice(&key_id(&own_key));
    header.extend_from_slice(&now_unix.to_be_bytes());
    header.extend_from_slice(&salt);
    header.push(unique.len() as u8);
    for recipient in &unique {
        let hpke_sender_private = <Kem as HpkeKem>::PrivateKey::from_bytes(&sender_bytes[..])
            .map_err(|_| SealError::Crypto)?;
        let hpke_recipient =
            <Kem as HpkeKem>::PublicKey::from_bytes(recipient).map_err(|_| SealError::Crypto)?;
        let mode = OpModeS::Auth((hpke_sender_private, hpke_sender_public.clone()));
        let mut rng = rand_core::OsRng.unwrap_err();
        let (encapped, context) = hpke::setup_sender::<HpkeChaCha20Poly1305, HkdfSha256, Kem, _>(
            &mode,
            &hpke_recipient,
            info.as_bytes(),
            &mut rng,
        )
        .map_err(|_| SealError::Crypto)?;
        let mut mask = Zeroizing::new([0u8; 32]);
        context
            .export(EXPORT_CONTEXT, &mut *mask)
            .map_err(|_| SealError::Crypto)?;
        header.extend_from_slice(&key_id(recipient));
        header.extend_from_slice(encapped.to_bytes().as_slice());
        let wrapped = std::array::from_fn::<_, 32, _>(|index| message_key[index] ^ mask[index]);
        header.extend_from_slice(&wrapped);
    }

    let cipher =
        ChaCha20Poly1305::new_from_slice(&message_key[..]).map_err(|_| SealError::Crypto)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&ZERO_NONCE),
            Payload {
                msg: &pad(body),
                aad: &header,
            },
        )
        .map_err(|_| SealError::Crypto)?;
    header.extend_from_slice(&encrypted);
    Ok(header)
}

fn unique_recipients(
    recipients: &[PublicKey],
    sender: &PrivateKey,
) -> Result<Vec<PublicKey>, SealError> {
    let own_key = sender.public_key();
    let mut seen = std::collections::HashSet::new();
    let unique: Vec<PublicKey> = recipients
        .iter()
        .copied()
        .filter(|key| *key != own_key && seen.insert(*key))
        .collect();
    if unique.is_empty() {
        return Err(SealError::NoRecipients);
    }
    if unique.len() > MAX_RECIPIENTS {
        return Err(SealError::TooManyRecipients);
    }
    Ok(unique)
}

fn recipient_message_key(
    recipient: &PrivateKey,
    sender: &PublicKey,
    encapped_key: &<Kem as HpkeKem>::EncappedKey,
    wrapped: &[u8],
    channel_id: u64,
) -> Option<Zeroizing<[u8; 32]>> {
    let recipient_bytes = recipient.to_bytes();
    let hpke_recipient = <Kem as HpkeKem>::PrivateKey::from_bytes(&recipient_bytes[..]).ok()?;
    let hpke_sender = <Kem as HpkeKem>::PublicKey::from_bytes(sender).ok()?;
    let mode = OpModeR::Auth(hpke_sender);
    let info = format!("duhcord-private-v2/{channel_id}");
    let context = hpke::setup_receiver::<HpkeChaCha20Poly1305, HkdfSha256, Kem>(
        &mode,
        &hpke_recipient,
        encapped_key,
        info.as_bytes(),
    )
    .ok()?;
    let mut mask = Zeroizing::new([0u8; 32]);
    context.export(EXPORT_CONTEXT, &mut *mask).ok()?;
    let mut message_key = Zeroizing::new([0u8; 32]);
    for index in 0..32 {
        message_key[index] = wrapped[index] ^ mask[index];
    }
    Some(message_key)
}

fn message_key(
    sender: &PrivateKey,
    salt: &[u8],
    channel_id: u64,
) -> Result<Zeroizing<[u8; 32]>, SealError> {
    let private_bytes = sender.to_bytes();
    let info = format!("duhcord-message-key-v2/{channel_id}");
    let hkdf = Hkdf::<Sha256>::new(Some(salt), &private_bytes[..]);
    let mut key = Zeroizing::new([0u8; 32]);
    hkdf.expand(info.as_bytes(), &mut *key)
        .map_err(|_| SealError::Crypto)?;
    Ok(key)
}

fn compress(raw: &[u8]) -> Result<Option<Vec<u8>>, SealError> {
    if raw.len() <= 16 {
        return Ok(None);
    }
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(raw).map_err(|_| SealError::Crypto)?;
    let compressed = encoder.finish().map_err(|_| SealError::Crypto)?;
    Ok((compressed.len() < raw.len()).then_some(compressed))
}

fn decompress(compressed: &[u8]) -> Option<Vec<u8>> {
    let decoder = DeflateDecoder::new(compressed);
    let mut output = Vec::new();
    decoder
        .take((MAX_PLAINTEXT + 1) as u64)
        .read_to_end(&mut output)
        .ok()?;
    (output.len() <= MAX_PLAINTEXT).then_some(output)
}

fn pad(bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity((bytes.len() + 2).div_ceil(128) * 128);
    let length = bytes.len() as u16;
    output.extend_from_slice(&length.to_be_bytes());
    output.extend_from_slice(bytes);
    output.resize(output.len().div_ceil(128) * 128, 0);
    output
}

fn unpad(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.len() < 2 {
        return None;
    }
    let length = usize::from(u16::from_be_bytes([bytes[0], bytes[1]]));
    if length > bytes.len() - 2 {
        return None;
    }
    Some(bytes[2..2 + length].to_vec())
}

#[cfg(test)]
pub(crate) fn seal_test_body(
    body: &[u8],
    flags: u8,
    channel_id: u64,
    sender: &PrivateKey,
    recipients: &[PublicKey],
) -> Result<Vec<u8>, SealError> {
    seal_frame(body, flags, channel_id, sender, recipients, 1_700_000_000)
}
