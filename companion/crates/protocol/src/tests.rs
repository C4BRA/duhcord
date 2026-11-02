use flate2::{write::DeflateEncoder, Compression};
use sha2::{Digest, Sha256};
use std::io::Write;

use crate::{
    dense_text,
    file::{open_file, padme, seal_file, FileKind, PrivateFile},
    handshake::{
        handshake_content, handshake_frame, kind, ClientClass, Features, Handshake, Host, Kind,
    },
    message::{open, seal, seal_test_body, SealError},
    safety::{key_code, key_id, safety_number},
    PrivateKey, MAX_PLAINTEXT, NOTICE, PREFIX,
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

fn content(frame: &[u8]) -> String {
    format!("{NOTICE}\n{PREFIX}{}", dense_text::encode(frame))
}

#[test]
fn handshakes_round_trip_with_receipts_and_unknown_hosts() {
    let key = [7; 32];
    let duhcord = Handshake {
        key,
        wants_reply: true,
        class: ClientClass::Duhcord,
        host: Host::UNKNOWN,
        features: Features::DUHCORD,
        accepted_key_ids: vec![],
    };
    assert_eq!(
        kind(&handshake_content(&duhcord)),
        Kind::Handshake(duhcord.clone())
    );
    let companion = Handshake {
        wants_reply: false,
        class: ClientClass::Companion,
        host: Host(255),
        features: Features::COMPANION_V1,
        // Out of order and duplicated on purpose: the frame carries them sorted and unique.
        accepted_key_ids: vec![[9, 9, 9, 9], [1, 2, 3, 4], [9, 9, 9, 9]],
        ..duhcord.clone()
    };
    let frame = handshake_frame(&companion);
    assert_eq!(frame.len(), 40 + 4 * 2);
    assert_eq!(&frame[..7], &[0x32, 0, 3, 1, 255, 0, 3]);
    let Kind::Handshake(decoded) = kind(&handshake_content(&companion)) else {
        panic!("companion handshake didn't parse");
    };
    assert_eq!(decoded.host, Host(255));
    assert_eq!(decoded.accepted_key_ids, vec![[1, 2, 3, 4], [9, 9, 9, 9]]);
}

#[test]
fn newer_versions_are_recognised_but_not_parsed() {
    let mut frame = handshake_frame(&Handshake {
        key: [7; 32],
        wants_reply: false,
        class: ClientClass::Duhcord,
        host: Host::UNKNOWN,
        features: Features::DUHCORD,
        accepted_key_ids: vec![],
    });
    frame[2] = 4;
    frame.extend_from_slice(&[0xaa; 5]); // a later version may be longer
    assert_eq!(kind(&content(&frame)), Kind::NewerHandshake { version: 4 });
    frame[2] = 2;
    assert_eq!(kind(&content(&frame)), Kind::Plain);
}

#[test]
fn malformed_frames_read_as_plain() {
    let base = handshake_frame(&Handshake {
        key: [7; 32],
        wants_reply: true,
        class: ClientClass::Duhcord,
        host: Host::UNKNOWN,
        features: Features::DUHCORD,
        accepted_key_ids: vec![[1, 1, 1, 1]],
    });
    let mut too_long = base.clone();
    too_long.push(0);
    let too_short = base[..base.len() - 1].to_vec();
    let mut nine = base[..39].to_vec();
    nine.push(9);
    nine.extend(std::iter::repeat_n(0u8, 36));
    let mut bad_flags = base.clone();
    bad_flags[1] = 0x02;
    let mut bad_client = base.clone();
    bad_client[3] = 2;
    for (why, frame) in [
        ("one byte too long", too_long),
        ("one byte too short", too_short),
        ("n = 9", nine),
        ("flags 0x02", bad_flags),
        ("client 2", bad_client),
    ] {
        assert_eq!(kind(&content(&frame)), Kind::Plain, "{why}");
    }

    let sender = PrivateKey::from_bytes([1; 32]);
    let recipient = PrivateKey::from_bytes([2; 32]);
    let sealed = seal(
        "hi",
        &[],
        CHANNEL_ID,
        &sender,
        &[recipient.public_key()],
        1_700_000_000,
    )
    .unwrap();
    let Kind::Encrypted(mut message) = kind(&sealed) else {
        panic!("sealed message didn't parse");
    };
    let mut no_recipients = message[..27].to_vec();
    no_recipients[26] = 0;
    no_recipients.extend_from_slice(&[0; 16]);
    assert_eq!(kind(&content(&no_recipients)), Kind::Plain, "n = 0");
    message[0] = 0x21;
    assert_eq!(kind(&content(&message)), Kind::Plain, "v2 type byte");
    assert_eq!(
        kind(&format!("dhc2:{}", dense_text::encode(&message))),
        Kind::Plain,
        "v2 prefix"
    );
    assert_eq!(kind("dhc3:!"), Kind::Plain);
}

#[test]
fn opened_messages_report_their_recipients() {
    let sender = PrivateKey::from_bytes([1; 32]);
    let recipient = PrivateKey::from_bytes([2; 32]);
    let sealed = seal(
        "hi",
        &[],
        CHANNEL_ID,
        &sender,
        &[recipient.public_key(), sender.public_key()],
        1_700_000_000,
    )
    .unwrap();
    let Kind::Encrypted(payload) = kind(&sealed) else {
        panic!("sealed message didn't parse");
    };
    let opened = open(
        &payload,
        CHANNEL_ID,
        &recipient,
        &[sender.public_key()],
        false,
    )
    .unwrap();
    assert_eq!(
        opened.recipient_key_ids,
        vec![key_id(&recipient.public_key())]
    );
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
