use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    ChaCha20Poly1305, Nonce,
};

use crate::{SealError, MAX_FILE_LENGTH};

const FILE_AAD: &[u8] = b"duhcord-file-v1";
const ZERO_NONCE: [u8; 12] = [0; 12];
const ENCODED_SIZE: usize = 45;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum FileKind {
    Jpeg = 1,
    Png = 2,
    Mp4 = 3,
    ReelChunk = 4,
}

impl TryFrom<u8> for FileKind {
    type Error = ();

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Jpeg),
            2 => Ok(Self::Png),
            3 => Ok(Self::Mp4),
            4 => Ok(Self::ReelChunk),
            _ => Err(()),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct PrivateFile {
    pub key: [u8; 32],
    pub length: u32,
    pub sealed_length: u32,
    pub width: u16,
    pub height: u16,
    pub kind: FileKind,
}

impl PrivateFile {
    pub fn encode(&self) -> [u8; ENCODED_SIZE] {
        let mut output = [0u8; ENCODED_SIZE];
        output[..32].copy_from_slice(&self.key);
        output[32..36].copy_from_slice(&self.length.to_be_bytes());
        output[36..40].copy_from_slice(&self.sealed_length.to_be_bytes());
        output[40..42].copy_from_slice(&self.width.to_be_bytes());
        output[42..44].copy_from_slice(&self.height.to_be_bytes());
        output[44] = self.kind as u8;
        output
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != ENCODED_SIZE {
            return None;
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&bytes[..32]);
        let file = Self {
            key,
            length: u32::from_be_bytes(bytes[32..36].try_into().ok()?),
            sealed_length: u32::from_be_bytes(bytes[36..40].try_into().ok()?),
            width: u16::from_be_bytes(bytes[40..42].try_into().ok()?),
            height: u16::from_be_bytes(bytes[42..44].try_into().ok()?),
            kind: FileKind::try_from(bytes[44]).ok()?,
        };
        file.is_valid().then_some(file)
    }

    pub(crate) fn is_valid(&self) -> bool {
        self.width > 0
            && self.height > 0
            && self.length <= MAX_FILE_LENGTH
            && usize::try_from(self.sealed_length).ok()
                == Some(padme(self.length as usize).saturating_add(16))
    }
}

pub fn seal_file(
    data: &[u8],
    width: u16,
    height: u16,
    kind: FileKind,
) -> Result<(PrivateFile, Vec<u8>), SealError> {
    if data.len() > MAX_FILE_LENGTH as usize || width == 0 || height == 0 {
        return Err(SealError::TooLong);
    }
    let padded_length = padme(data.len());
    let sealed_length = padded_length.checked_add(16).ok_or(SealError::TooLong)?;
    let length = u32::try_from(data.len()).map_err(|_| SealError::TooLong)?;
    let sealed_length = u32::try_from(sealed_length).map_err(|_| SealError::TooLong)?;

    let mut key = zeroize::Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut *key).map_err(|_| SealError::Crypto)?;
    let mut padded = data.to_vec();
    padded.resize(padded_length, 0);
    let cipher = ChaCha20Poly1305::new_from_slice(&*key).map_err(|_| SealError::Crypto)?;
    let sealed = cipher
        .encrypt(
            Nonce::from_slice(&ZERO_NONCE),
            Payload {
                msg: &padded,
                aad: FILE_AAD,
            },
        )
        .map_err(|_| SealError::Crypto)?;
    let file = PrivateFile {
        key: *key,
        length,
        sealed_length,
        width,
        height,
        kind,
    };
    Ok((file, sealed))
}

pub fn open_file(sealed: &[u8], file: &PrivateFile) -> Option<Vec<u8>> {
    if !file.is_valid() || sealed.len() != file.sealed_length as usize {
        return None;
    }
    let cipher = ChaCha20Poly1305::new_from_slice(&file.key).ok()?;
    let mut plain = cipher
        .decrypt(
            Nonce::from_slice(&ZERO_NONCE),
            Payload {
                msg: sealed,
                aad: FILE_AAD,
            },
        )
        .ok()?;
    if plain.len() < file.length as usize {
        return None;
    }
    plain.truncate(file.length as usize);
    Some(plain)
}

pub fn padme(length: usize) -> usize {
    if length <= 1 {
        return length.max(1);
    }
    let exponent = (usize::BITS - 1 - length.leading_zeros()) as usize;
    let shift = (usize::BITS - exponent.leading_zeros()) as usize;
    let mask = (1usize << (exponent - shift)) - 1;
    length
        .checked_add(mask)
        .map(|rounded| rounded & !mask)
        .unwrap_or(length)
}
