#![forbid(unsafe_code)]

use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use directories::ProjectDirs;
use duhcord_companion_engine::{AccountKeys, Directory};
use keyring::{Entry, Error as KeyringError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::{Zeroize, Zeroizing};

const SERVICE: &str = "com.duhcord.companion";
const DIRECTORY_AAD_PREFIX: &str = "duhcord-companion-directory-v1/";
const NONCE_LENGTH: usize = 24;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("secure storage is locked: {0}")]
    Locked(String),
    #[error("store I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("store serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("cryptographic operation failed")]
    Crypto,
    #[error("account already exists")]
    AlreadyExists,
    #[error("pairing data is corrupt")]
    PairingsCorrupt,
}

#[derive(Serialize, Deserialize)]
struct KeyringMaterial {
    private_key: String,
    directory_key: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingRecord {
    pub token_hash: String,
    pub host: String,
    pub user_id: u64,
    pub created_at: u64,
}

#[derive(Default, Serialize, Deserialize)]
struct PairingsFile {
    pairings: Vec<PairingRecord>,
}

pub struct Store {
    config_dir: PathBuf,
    entries: Mutex<std::collections::HashMap<String, Entry>>,
}

impl Store {
    pub fn open(config_dir: impl AsRef<Path>) -> Result<Self, StoreError> {
        let config_dir = config_dir.as_ref().to_path_buf();
        fs::create_dir_all(config_dir.join("accounts"))?;
        Ok(Self {
            config_dir,
            entries: Mutex::new(std::collections::HashMap::new()),
        })
    }

    pub fn default_config_dir() -> Result<PathBuf, StoreError> {
        ProjectDirs::from("", "", "DuhcordCompanion")
            .map(|dirs| dirs.config_dir().to_path_buf())
            .ok_or_else(|| StoreError::Io(std::io::Error::other("no config directory available")))
    }

    pub fn load_account(
        &self,
        user_id: u64,
    ) -> Result<Option<(AccountKeys, Directory)>, StoreError> {
        let password = match self.with_entry(user_id, Entry::get_password) {
            Ok(password) => password,
            Err(KeyringError::NoEntry) => return Ok(None),
            Err(error) => return Err(locked(error)),
        };
        let password = Zeroizing::new(password);
        let mut material: KeyringMaterial = serde_json::from_str(&password)
            .map_err(|_| StoreError::Locked("invalid keyring data".to_owned()))?;
        let private_key = decode_key(&material.private_key);
        let directory_key = decode_key(&material.directory_key);
        material.private_key.zeroize();
        material.directory_key.zeroize();
        let private_key = Zeroizing::new(private_key?);
        let directory_key = Zeroizing::new(directory_key?);
        let account = AccountKeys::new(user_id, *private_key, *directory_key);
        let directory = self.load_directory(&account)?;
        Ok(Some((account, directory)))
    }

    pub fn create_account(&self, user_id: u64) -> Result<AccountKeys, StoreError> {
        match self.with_entry(user_id, Entry::get_password) {
            Ok(_) => return Err(StoreError::AlreadyExists),
            Err(KeyringError::NoEntry) => {}
            Err(error) => return Err(locked(error)),
        }
        let mut private_key = Zeroizing::new([0u8; 32]);
        let mut directory_key = Zeroizing::new([0u8; 32]);
        getrandom::fill(&mut *private_key).map_err(|_| StoreError::Crypto)?;
        getrandom::fill(&mut *directory_key).map_err(|_| StoreError::Crypto)?;
        let account = AccountKeys::new(user_id, *private_key, *directory_key);
        let mut material = KeyringMaterial {
            private_key: STANDARD.encode(account.private_key_bytes().as_ref()),
            directory_key: STANDARD.encode(account.directory_key()),
        };
        let password = Zeroizing::new(serde_json::to_string(&material)?);
        material.private_key.zeroize();
        material.directory_key.zeroize();
        self.with_entry(user_id, |entry| entry.set_password(&password))
            .map_err(locked)?;
        Ok(account)
    }

    pub fn save_directory(
        &self,
        account: &AccountKeys,
        directory: &Directory,
    ) -> Result<(), StoreError> {
        let mut nonce = [0u8; NONCE_LENGTH];
        getrandom::fill(&mut nonce).map_err(|_| StoreError::Crypto)?;
        let mut plain = Zeroizing::new(serde_json::to_vec(directory)?);
        let aad = format!("{DIRECTORY_AAD_PREFIX}{}", account.user_id());
        let cipher = XChaCha20Poly1305::new_from_slice(account.directory_key())
            .map_err(|_| StoreError::Crypto)?;
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &plain,
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|_| StoreError::Crypto)?;
        plain.zeroize();

        let mut file = Vec::with_capacity(NONCE_LENGTH + ciphertext.len());
        file.extend_from_slice(&nonce);
        file.extend_from_slice(&ciphertext);
        let path = self.directory_path(account.user_id());
        fs::create_dir_all(path.parent().expect("account path has a parent"))?;
        fs::write(path, file)?;
        Ok(())
    }

    pub fn add_pairing(
        &self,
        token: &[u8],
        host: &str,
        user_id: u64,
    ) -> Result<PairingRecord, StoreError> {
        let record = PairingRecord {
            token_hash: hex(&Sha256::digest(token)),
            host: host.to_owned(),
            user_id,
            created_at: now(),
        };
        let mut file = self.read_pairings()?;
        file.pairings
            .retain(|pairing| pairing.host != host || pairing.user_id != user_id);
        file.pairings.push(record.clone());
        self.write_pairings(&file)?;
        Ok(record)
    }

    pub fn has_pairing(&self, token: &[u8], host: &str, user_id: u64) -> Result<bool, StoreError> {
        let token_hash = hex(&Sha256::digest(token));
        Ok(self.read_pairings()?.pairings.iter().any(|pairing| {
            pairing.token_hash == token_hash && pairing.host == host && pairing.user_id == user_id
        }))
    }

    pub fn pairings(&self) -> Result<Vec<PairingRecord>, StoreError> {
        Ok(self.read_pairings()?.pairings)
    }

    pub fn revoke_pairing(&self, token_hash: &[u8; 32]) -> Result<bool, StoreError> {
        let token_hash = hex(token_hash);
        let mut file = self.read_pairings()?;
        let initial = file.pairings.len();
        file.pairings
            .retain(|pairing| pairing.token_hash != token_hash);
        let changed = file.pairings.len() != initial;
        if changed {
            self.write_pairings(&file)?;
        }
        Ok(changed)
    }

    pub fn pairing_hash(token: &[u8]) -> [u8; 32] {
        Sha256::digest(token).into()
    }

    fn load_directory(&self, account: &AccountKeys) -> Result<Directory, StoreError> {
        let path = self.directory_path(account.user_id());
        let contents = match fs::read(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Directory::default());
            }
            Err(error) => return Err(error.into()),
        };
        if contents.len() <= NONCE_LENGTH {
            return Err(StoreError::Locked(
                "encrypted directory is truncated".to_owned(),
            ));
        }
        let (nonce, ciphertext) = contents.split_at(NONCE_LENGTH);
        let aad = format!("{DIRECTORY_AAD_PREFIX}{}", account.user_id());
        let cipher = XChaCha20Poly1305::new_from_slice(account.directory_key())
            .map_err(|_| StoreError::Crypto)?;
        let mut plain = Zeroizing::new(
            cipher
                .decrypt(
                    XNonce::from_slice(nonce),
                    Payload {
                        msg: ciphertext,
                        aad: aad.as_bytes(),
                    },
                )
                .map_err(|_| StoreError::Locked("directory authentication failed".to_owned()))?,
        );
        let directory = serde_json::from_slice(&plain)
            .map_err(|_| StoreError::Locked("directory data is corrupt".to_owned()))?;
        plain.zeroize();
        Ok(directory)
    }

    fn directory_path(&self, user_id: u64) -> PathBuf {
        self.config_dir
            .join("accounts")
            .join(format!("{user_id}.dir"))
    }

    fn pairings_path(&self) -> PathBuf {
        self.config_dir.join("pairings.json")
    }

    fn read_pairings(&self) -> Result<PairingsFile, StoreError> {
        let path = self.pairings_path();
        match fs::read(path) {
            Ok(contents) => {
                serde_json::from_slice(&contents).map_err(|_| StoreError::PairingsCorrupt)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Ok(PairingsFile::default())
            }
            Err(error) => Err(error.into()),
        }
    }

    fn write_pairings(&self, pairings: &PairingsFile) -> Result<(), StoreError> {
        let serialized = serde_json::to_vec_pretty(pairings)?;
        fs::write(self.pairings_path(), serialized)?;
        Ok(())
    }

    fn with_entry<T>(
        &self,
        user_id: u64,
        operation: impl FnOnce(&Entry) -> Result<T, KeyringError>,
    ) -> Result<T, KeyringError> {
        let account = user_id.to_string();
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !entries.contains_key(&account) {
            let entry = Entry::new(SERVICE, &account)?;
            entries.insert(account.clone(), entry);
        }
        operation(entries.get(&account).expect("entry was inserted"))
    }
}

fn decode_key(encoded: &str) -> Result<[u8; 32], StoreError> {
    let bytes = Zeroizing::new(
        STANDARD
            .decode(encoded)
            .map_err(|_| StoreError::Locked("invalid keyring data".to_owned()))?,
    );
    if bytes.len() != 32 {
        return Err(StoreError::Locked("invalid keyring data".to_owned()));
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Ok(key)
}

fn locked(error: KeyringError) -> StoreError {
    StoreError::Locked(error.to_string())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests;
