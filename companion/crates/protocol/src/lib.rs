#![forbid(unsafe_code)]

pub mod dense_text;
mod file;
mod handshake;
mod key;
mod message;
mod safety;

pub use dense_text::{decode as decode_dense_text, encode as encode_dense_text};
pub use file::{open_file, padme, seal_file, FileKind, PrivateFile};
pub use handshake::{handshake_content, kind, ClientClass, Features, Handshake, Host, Kind};
pub use key::PrivateKey;
pub use message::{open, seal, Opened, SealError};
pub use safety::{key_code, key_id, safety_number};

pub const PREFIX: &str = "dhc2:";
pub const NOTICE: &str = "-# encrypted messaging by C4BRA/duhcord 🤫";
pub const MAX_CONTENT_UTF16: usize = 2000;
pub const MAX_RECIPIENTS: usize = 8;
pub const MAX_PLAINTEXT: usize = 65_536;
pub const MAX_FILES: usize = 4;
pub const MAX_FILE_LENGTH: u32 = 50 * 1024 * 1024;

pub type PublicKey = [u8; 32];

#[cfg(test)]
mod tests;
