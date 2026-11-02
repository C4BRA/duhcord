use std::collections::BTreeMap;

use sha2::{Digest, Sha256, Sha512};

use crate::{ClientClass, PublicKey};

pub fn key_id(key: &PublicKey) -> [u8; 4] {
    let digest = Sha256::digest(key);
    digest[..4].try_into().unwrap()
}

pub fn safety_number(a: &[(PublicKey, ClientClass)], b: &[(PublicKey, ClientClass)]) -> String {
    let version_3 = a
        .iter()
        .chain(b)
        .any(|(_, class)| *class == ClientClass::Companion);
    let mut first_side = side(a, version_3);
    let mut second_side = side(b, version_3);
    if second_side < first_side {
        std::mem::swap(&mut first_side, &mut second_side);
    }
    let mut input = if version_3 {
        b"duhcord-safety-number-v3".to_vec()
    } else {
        b"duhcord-safety-number-v2".to_vec()
    };
    input.extend_from_slice(&first_side);
    input.extend_from_slice(&second_side);
    digits(&input, 12)
}

pub fn key_code(key: &PublicKey) -> String {
    let mut input = b"duhcord-key-code-v1".to_vec();
    input.extend_from_slice(key);
    digits(&input, 6)
}

fn side(keys: &[(PublicKey, ClientClass)], version_3: bool) -> Vec<u8> {
    let mut unique = BTreeMap::new();
    for (key, class) in keys {
        unique
            .entry(*key)
            .and_modify(|existing| {
                if *class == ClientClass::Companion {
                    *existing = ClientClass::Companion;
                }
            })
            .or_insert(*class);
    }
    let mut output = Vec::with_capacity(1 + unique.len() * if version_3 { 33 } else { 32 });
    output.push(unique.len().min(usize::from(u8::MAX)) as u8);
    for (key, class) in unique {
        output.extend_from_slice(&key);
        if version_3 {
            output.push(class as u8);
        }
    }
    output
}

fn digits(input: &[u8], groups: usize) -> String {
    let first = Sha512::digest(input);
    let second = Sha512::digest(first);
    let mut bytes = [0u8; 128];
    bytes[..64].copy_from_slice(&first);
    bytes[64..].copy_from_slice(&second);
    (0..groups)
        .map(|group| {
            let start = group * 5;
            let value = bytes[start..start + 5]
                .iter()
                .fold(0u64, |value, byte| (value << 8) | u64::from(*byte));
            format!("{:05}", value % 100_000)
        })
        .collect::<Vec<_>>()
        .join(" ")
}
