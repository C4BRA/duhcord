use flate2::{write::DeflateEncoder, Compression};
use sha2::{Digest, Sha256};
use std::io::Write;

use crate::{
    dense_text,
    file::{open_file, padme, seal_file, FileKind, PrivateFile},
    handshake::{handshake_content, kind, ClientClass, Features, Handshake, Host, Kind},
    message::{open, seal, seal_test_body, SealError},
    safety::{key_code, safety_number},
    PrivateKey, MAX_PLAINTEXT,
};

const CHANNEL_ID: u64 = 1_100_000_000_000_000_001;

fn private_key(seed: u8) -> PrivateKey {
    PrivateKey::from_bytes([seed; 32])
}

fn encrypted_payload(content: &str) -> Vec<u8> {
    match kind(content) {
        Kind::Encrypted(payload) => payload,
        other => panic!("expected encrypted content, got {other:?}"),
    }
}

#[test]
fn message_round_trip_with_text_files_self_and_eight_recipients() {
    let sender = private_key(1);
    let bob = private_key(2);
    let file = PrivateFile {
        key: [3; 32],
        length: 5,
        sealed_length: (padme(5) + 16) as u32,
        width: 10,
        height: 10,
        kind: FileKind::Png,
    };
    let mut recipients = vec![bob.public_key(), sender.public_key()];
    let extras: Vec<_> = (10..17)
        .map(|seed| private_key(seed).public_key())
        .collect();
    recipients.extend(extras);

    let content = seal(
        "Hello 👋",
        std::slice::from_ref(&file),
        CHANNEL_ID,
        &sender,
        &recipients,
        1_700_000_000,
    )
    .unwrap();
    let payload = encrypted_payload(&content);
    let opened = open(&payload, CHANNEL_ID, &bob, &[sender.public_key()], false).unwrap();
    assert_eq!(opened.text, "Hello 👋");
    assert!(opened.files == [file]);
    assert_eq!(opened.sent_at, 1_700_000_000);

    let self_opened = open(&payload, CHANNEL_ID, &sender, &[], true).unwrap();
    assert_eq!(self_opened.text, "Hello 👋");

    let too_many: Vec<_> = (30..39)
        .map(|seed| private_key(seed).public_key())
        .collect();
    assert_eq!(
        seal("hi", &[], CHANNEL_ID, &sender, &too_many, 0),
        Err(SealError::TooManyRecipients)
    );
}

#[test]
fn sender_key_is_removed_before_recipient_count_and_deduplication() {
    let sender = private_key(1);
    let bob = private_key(2);
    let recipients = [sender.public_key(), bob.public_key(), bob.public_key()];
    let content = seal("hi", &[], CHANNEL_ID, &sender, &recipients, 0).unwrap();
    assert_eq!(
        open(
            &encrypted_payload(&content),
            CHANNEL_ID,
            &bob,
            &[sender.public_key()],
            false
        )
        .unwrap()
        .text,
        "hi"
    );
    assert_eq!(
        seal("hi", &[], CHANNEL_ID, &sender, &[sender.public_key()], 0),
        Err(SealError::NoRecipients)
    );
}

#[test]
fn wrong_recipient_and_every_single_byte_tamper_fail() {
    let sender = private_key(1);
    let recipient = private_key(2);
    let wrong = private_key(3);
    let payload = encrypted_payload(
        &seal(
            "authenticated body",
            &[],
            CHANNEL_ID,
            &sender,
            &[recipient.public_key()],
            123,
        )
        .unwrap(),
    );
    assert!(open(&payload, CHANNEL_ID, &wrong, &[sender.public_key()], false).is_none());

    for index in 0..payload.len() {
        let mut tampered = payload.clone();
        tampered[index] ^= 1;
        assert!(
            open(
                &tampered,
                CHANNEL_ID,
                &recipient,
                &[sender.public_key()],
                false
            )
            .is_none(),
            "tampering at byte {index} should fail"
        );
    }
}

#[test]
fn compression_is_used_for_repetitive_text() {
    let sender = private_key(1);
    let recipient = private_key(2);
    let content = seal(
        &"repetitive ".repeat(200),
        &[],
        CHANNEL_ID,
        &sender,
        &[recipient.public_key()],
        0,
    )
    .unwrap();
    assert_eq!(encrypted_payload(&content)[1] & 1, 1);
}

#[test]
fn decompression_bomb_is_rejected() {
    let sender = private_key(1);
    let recipient = private_key(2);
    let bomb = vec![b'x'; MAX_PLAINTEXT + 1];
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(&bomb).unwrap();
    let compressed = encoder.finish().unwrap();
    let payload = seal_test_body(
        &compressed,
        1,
        CHANNEL_ID,
        &sender,
        &[recipient.public_key()],
    )
    .unwrap();
    assert!(open(
        &payload,
        CHANNEL_ID,
        &recipient,
        &[sender.public_key()],
        false
    )
    .is_none());
}

#[test]
fn handshake_and_malformed_frames_follow_wire_lengths() {
    let key = [7; 32];
    let handshake = Handshake {
        key,
        wants_reply: true,
        class: ClientClass::Duhcord,
        host: Host::Unknown,
        features: Features::DUHCORD,
    };
    assert!(matches!(
        kind(&handshake_content(&handshake)),
        Kind::Handshake(decoded) if decoded.key == key && decoded.wants_reply
    ));
    let companion = Handshake {
        class: ClientClass::Companion,
        host: Host::Vencord,
        features: Features::COMPANION_V1,
        ..handshake
    };
    assert!(matches!(
        kind(&handshake_content(&companion)),
        Kind::Handshake(decoded) if decoded == companion
    ));
    let mut unknown_host = vec![0x23, 0, 1, 0xff, 0, 3];
    unknown_host.extend_from_slice(&key);
    assert!(matches!(
        kind(&format!("dhc2:{}", dense_text::encode(&unknown_host))),
        Kind::Handshake(decoded) if decoded.host == Host::Unknown
    ));

    for size in [33, 35] {
        let mut frame = vec![0x22, 0];
        frame.resize(size, 0);
        assert_eq!(
            kind(&format!("dhc2:{}", dense_text::encode(&frame))),
            Kind::Plain
        );
    }
    let mut invalid_companion = vec![0x23, 0, 0, Host::Unknown as u8, 0, 3];
    invalid_companion.extend_from_slice(&key);
    assert_eq!(
        kind(&format!("dhc2:{}", dense_text::encode(&invalid_companion))),
        Kind::Plain
    );
    assert_eq!(kind("dhc2:!"), Kind::Plain);
}

#[test]
fn padme_matches_protocol_vectors() {
    for (input, expected) in [
        (0, 1),
        (1, 1),
        (2, 2),
        (9, 10),
        (1000, 1024),
        (70000, 71680),
    ] {
        assert_eq!(padme(input), expected);
    }
}

#[test]
fn file_round_trip_requires_exact_sealed_length() {
    let data: Vec<u8> = (0..=255).cycle().take(5000).collect();
    let (file, sealed) = seal_file(&data, 10, 10, FileKind::Png).unwrap();
    assert_eq!(open_file(&sealed, &file), Some(data));
    assert!(open_file(&sealed[..sealed.len() - 1], &file).is_none());
}

#[test]
fn safety_numbers_are_symmetric_and_class_sensitive() {
    let alice: [u8; 32] = Sha256::digest(b"alice").into();
    let bob: [u8; 32] = Sha256::digest(b"bob").into();
    let a = [(alice, ClientClass::Duhcord)];
    let b = [(bob, ClientClass::Duhcord)];
    assert_eq!(safety_number(&a, &b), safety_number(&b, &a));
    assert_ne!(
        safety_number(&a, &b),
        safety_number(&[(alice, ClientClass::Companion)], &b)
    );
    assert_eq!(key_code(&alice).split(' ').count(), 6);
}
