use rand_core::TryRngCore;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::PublicKey;

pub struct PrivateKey(StaticSecret);

impl PrivateKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(StaticSecret::from(bytes))
    }

    pub fn generate() -> Self {
        let mut bytes = Zeroizing::new([0u8; 32]);
        rand_core::OsRng
            .try_fill_bytes(&mut *bytes)
            .expect("operating system random number generator failed");
        Self::from_bytes(*bytes)
    }

    pub fn public_key(&self) -> PublicKey {
        X25519PublicKey::from(&self.0).to_bytes()
    }

    pub fn to_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.0.to_bytes())
    }
}
