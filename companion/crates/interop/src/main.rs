#![forbid(unsafe_code)]

use std::{
    collections::{BTreeMap, HashMap},
    env, fs,
    path::Path,
    process::ExitCode,
};

use duhcord_private_protocol::{
    dense_text, frame_content, handshake_content, handshake_frame, key_code, key_id, kind, open,
    open_file, padme, safety_number, seal, seal_file, ClientClass, Features, FileKind, Handshake,
    Host, Kind, PrivateFile, PrivateKey, PublicKey, NOTICE,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256, Sha512};

const CHANNEL_ID: u64 = 1_100_000_000_000_000_001;
const CHANNEL_ID_TEXT: &str = "1100000000000000001";
const SENT_AT: u32 = 1_700_000_000;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Vectors {
    version: u8,
    #[serde(rename = "impl")]
    implementation: String,
    channel_id: String,
    public_keys: BTreeMap<String, String>,
    messages: Vec<MessageVector>,
    file_blobs: Vec<FileBlobVector>,
    handshakes: Vec<HandshakeVector>,
    dense_text: Vec<DenseTextVector>,
    padme: Vec<[usize; 2]>,
    safety_numbers: Vec<SafetyNumberVector>,
    key_codes: Vec<KeyCodeVector>,
    rejects: Vec<RejectVector>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageVector {
    name: String,
    sender: String,
    recipients: Vec<String>,
    text: String,
    files: Vec<String>,
    content: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileBlobVector {
    file: String,
    sealed: String,
    plain: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HandshakeVector {
    key: String,
    wants_reply: bool,
    client: u8,
    host: u8,
    features: u16,
    accepted_key_ids: Vec<String>,
    content: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RejectVector {
    why: String,
    content: String,
}

/// One fixed handshake: key, wantsReply, client, host, features, accepted keys (by name).
type FixedHandshake = (&'static str, bool, u8, u8, u16, &'static [&'static str]);

/// The fixed handshakes (spec/VECTORS.md).
const FIXED_HANDSHAKES: [FixedHandshake; 4] = [
    ("alice", true, 0, 0, Features::DUHCORD.0, &[]),
    ("bob", false, 0, 0, Features::DUHCORD.0, &["alice"]),
    ("carol", true, 1, 4, Features::COMPANION_V1.0, &[]),
    (
        "dave",
        false,
        1,
        255,
        Features::COMPANION_V1.0,
        &["alice", "bob", "carol"],
    ),
];

/// The required rejects, in order (spec/VECTORS.md): each must read as plain.
const REJECT_REASONS: [&str; 8] = [
    "handshake one byte too long",
    "handshake one byte too short",
    "handshake with n = 9",
    "handshake with flags 0x02",
    "handshake with client 2",
    "message with n = 0",
    "v2 message (type 0x21, dhc2: prefix)",
    "v3 message with type byte 0x21",
];

fn vector_handshake(
    name: &str,
    wants_reply: bool,
    client: u8,
    host: u8,
    features: u16,
    accepted: &[&str],
) -> Option<Handshake> {
    // Sorted and unique, as they travel in the frame.
    let mut accepted_key_ids: Vec<_> = accepted
        .iter()
        .map(|name| key_id(&vector_private_key(name).public_key()))
        .collect();
    accepted_key_ids.sort_unstable();
    accepted_key_ids.dedup();
    Some(Handshake {
        key: vector_private_key(name).public_key(),
        wants_reply,
        class: ClientClass::from_byte(client)?,
        host: Host(host),
        features: Features(features),
        accepted_key_ids,
    })
}

fn sorted_hex_ids(handshake: &Handshake) -> Vec<String> {
    let mut ids: Vec<_> = handshake.accepted_key_ids.iter().map(hex::encode).collect();
    ids.sort();
    ids.dedup();
    ids
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DenseTextVector {
    bytes: String,
    text: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SafetyNumberVector {
    a: Vec<String>,
    b: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    a_companion: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    b_companion: Vec<String>,
    number: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyCodeVector {
    key: String,
    code: String,
}

struct ExpectedMessage {
    name: &'static str,
    sender: &'static str,
    recipients: &'static [&'static str],
    text: String,
    files: Vec<String>,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    match (args.next().as_deref(), args.next(), args.next()) {
        (Some("gen"), Some(path), None) => {
            let vectors = generate_vectors()?;
            let json = serde_json::to_vec_pretty(&vectors)
                .map_err(|error| format!("serialize vectors: {error}"))?;
            fs::write(&path, json).map_err(|error| format!("write {path}: {error}"))?;
            println!("wrote {path}");
            Ok(())
        }
        (Some("check"), Some(path), None) => {
            check_path(Path::new(&path))?;
            println!("all interop checks passed: {path}");
            Ok(())
        }
        _ => Err("usage: duhcord-interop gen <out.json> | check <their.json>".to_owned()),
    }
}

fn generate_vectors() -> Result<Vectors, String> {
    let private_keys: HashMap<String, PrivateKey> = ["alice", "bob", "carol", "dave"]
        .into_iter()
        .map(|name| (name.to_owned(), vector_private_key(name)))
        .collect();
    let public_keys: BTreeMap<String, String> = private_keys
        .iter()
        .map(|(name, key)| (name.clone(), hex::encode(key.public_key())))
        .collect();
    let alice = private_keys.get("alice").unwrap();
    let bob = private_keys.get("bob").unwrap();
    let carol = private_keys.get("carol").unwrap();

    let file_zero = vector_file(b"file-0", 1000, 640, 480, FileKind::Jpeg);
    let file_one = vector_file(b"file-1", 70_000, 1, 1, FileKind::Png);
    let short = build_message("short", "alice", &["bob"], &[], "hi", &[], &private_keys)?;
    let unicode = build_message(
        "unicode",
        "bob",
        &["alice"],
        &[],
        "héllo 🙋 世界\nsecond line",
        &[],
        &private_keys,
    )?;
    let compressible = build_message(
        "compressible",
        "alice",
        &["bob", "carol", "dave"],
        &[],
        &"private ".repeat(120),
        &[],
        &private_keys,
    )?;
    let incompressible_text = hex::encode(Sha512::digest(b"x"));
    let incompressible = build_message(
        "incompressible",
        "carol",
        &["alice"],
        &[],
        &incompressible_text,
        &[],
        &private_keys,
    )?;
    let files = build_message(
        "files",
        "alice",
        &["bob"],
        &[],
        "two pictures",
        &[file_zero.clone(), file_one.clone()],
        &private_keys,
    )?;
    let extra_recipients: Vec<PublicKey> = (0..5)
        .map(|_| PrivateKey::generate().public_key())
        .collect();
    let max_recipients = build_message(
        "max-recipients",
        "dave",
        &["alice", "bob", "carol"],
        &extra_recipients,
        "eight recipients",
        &[],
        &private_keys,
    )?;

    let file_blob_plain: Vec<u8> = (0..=255).cycle().take(5000).collect();
    let (file_blob, sealed_file_blob) =
        seal_file(&file_blob_plain, 10, 10, FileKind::Png).map_err(|error| error.to_string())?;
    let file_blobs = vec![FileBlobVector {
        file: hex::encode(file_blob.encode()),
        sealed: hex::encode(sealed_file_blob),
        plain: hex::encode(&file_blob_plain),
    }];

    let handshakes = FIXED_HANDSHAKES
        .iter()
        .map(|&(name, wants_reply, client, host, features, accepted)| {
            let handshake =
                vector_handshake(name, wants_reply, client, host, features, accepted)
                    .ok_or_else(|| format!("fixed handshake {name} has an invalid client"))?;
            Ok(HandshakeVector {
                key: name.to_owned(),
                wants_reply,
                client,
                host,
                features,
                accepted_key_ids: sorted_hex_ids(&handshake),
                content: handshake_content(&handshake),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;

    let dense_inputs = dense_inputs();
    let dense_text = dense_inputs
        .iter()
        .map(|bytes| DenseTextVector {
            bytes: hex::encode(bytes),
            text: dense_text::encode(bytes),
        })
        .collect();
    let padme_vectors = [
        [0, 1],
        [1, 1],
        [2, 2],
        [9, 10],
        [1000, 1024],
        [70000, 71680],
    ];
    let alice_public = alice.public_key();
    let bob_public = bob.public_key();
    let carol_public = carol.public_key();
    let safety_numbers = vec![
        SafetyNumberVector {
            a: vec!["alice".to_owned()],
            b: vec!["bob".to_owned()],
            a_companion: Vec::new(),
            b_companion: Vec::new(),
            number: safety_number(
                &[(alice_public, ClientClass::Duhcord)],
                &[(bob_public, ClientClass::Duhcord)],
            ),
        },
        SafetyNumberVector {
            a: vec!["alice".to_owned(), "carol".to_owned()],
            b: vec!["bob".to_owned()],
            a_companion: Vec::new(),
            b_companion: Vec::new(),
            number: safety_number(
                &[
                    (alice_public, ClientClass::Duhcord),
                    (carol_public, ClientClass::Duhcord),
                ],
                &[(bob_public, ClientClass::Duhcord)],
            ),
        },
        SafetyNumberVector {
            a: vec!["alice".to_owned()],
            b: vec!["carol".to_owned()],
            a_companion: Vec::new(),
            b_companion: vec!["carol".to_owned()],
            number: safety_number(
                &[(alice_public, ClientClass::Duhcord)],
                &[(carol_public, ClientClass::Companion)],
            ),
        },
        SafetyNumberVector {
            a: vec!["alice".to_owned(), "bob".to_owned()],
            b: vec!["carol".to_owned(), "dave".to_owned()],
            a_companion: Vec::new(),
            b_companion: vec!["dave".to_owned()],
            number: safety_number(
                &[
                    (alice_public, ClientClass::Duhcord),
                    (bob_public, ClientClass::Duhcord),
                ],
                &[
                    (carol_public, ClientClass::Duhcord),
                    (private_keys["dave"].public_key(), ClientClass::Companion),
                ],
            ),
        },
        SafetyNumberVector {
            a: vec!["alice".to_owned()],
            b: vec!["alice".to_owned()],
            a_companion: vec!["alice".to_owned()],
            b_companion: Vec::new(),
            number: safety_number(
                &[(alice_public, ClientClass::Companion)],
                &[(alice_public, ClientClass::Duhcord)],
            ),
        },
        SafetyNumberVector {
            a: vec!["bob".to_owned()],
            b: vec!["alice".to_owned()],
            a_companion: Vec::new(),
            b_companion: Vec::new(),
            number: safety_number(
                &[(bob_public, ClientClass::Duhcord)],
                &[(alice_public, ClientClass::Duhcord)],
            ),
        },
    ];
    let key_codes = vec![KeyCodeVector {
        key: "alice".to_owned(),
        code: key_code(&alice_public),
    }];

    let rejects = reject_contents(&short.content)?
        .into_iter()
        .zip(REJECT_REASONS)
        .map(|(content, why)| RejectVector {
            why: why.to_owned(),
            content,
        })
        .collect();

    Ok(Vectors {
        version: 3,
        implementation: "rust".to_owned(),
        channel_id: CHANNEL_ID_TEXT.to_owned(),
        public_keys,
        messages: vec![
            short,
            unicode,
            compressible,
            incompressible,
            files,
            max_recipients,
        ],
        file_blobs,
        handshakes,
        dense_text,
        padme: padme_vectors.into_iter().collect(),
        safety_numbers,
        key_codes,
        rejects,
    })
}

/// Builds the required rejects from the fixed bob handshake and the `short` message (spec/VECTORS.md).
fn reject_contents(short_message: &str) -> Result<Vec<String>, String> {
    let (name, wants_reply, client, host, features, accepted) = FIXED_HANDSHAKES[1];
    let handshake = vector_handshake(name, wants_reply, client, host, features, accepted)
        .ok_or("fixed handshake has an invalid client")?;
    let base = handshake_frame(&handshake);
    let mut too_long = base.clone();
    too_long.push(0);
    let too_short = base[..base.len() - 1].to_vec();
    let mut nine = base[..39].to_vec();
    nine.push(9);
    nine.extend(std::iter::repeat_n(0u8, 36));
    let mut bad_flags = base.clone();
    bad_flags[1] = 0x02;
    let mut bad_client = base;
    bad_client[3] = 2;

    let Kind::Encrypted(message) = kind(short_message) else {
        return Err("the short message didn't parse".to_owned());
    };
    let mut no_recipients = message[..27].to_vec();
    no_recipients[26] = 0;
    no_recipients.extend_from_slice(&[0; 16]);
    let mut v2_type = message;
    v2_type[0] = 0x21;
    let v2 = format!("{NOTICE}\ndhc2:{}", dense_text::encode(&v2_type));

    Ok(vec![
        frame_content(&too_long),
        frame_content(&too_short),
        frame_content(&nine),
        frame_content(&bad_flags),
        frame_content(&bad_client),
        frame_content(&no_recipients),
        v2,
        frame_content(&v2_type),
    ])
}

fn build_message(
    name: &str,
    sender_name: &str,
    recipient_names: &[&str],
    extra_recipients: &[PublicKey],
    text: &str,
    files: &[PrivateFile],
    private_keys: &HashMap<String, PrivateKey>,
) -> Result<MessageVector, String> {
    let sender = private_keys
        .get(sender_name)
        .ok_or_else(|| format!("unknown sender {sender_name}"))?;
    let mut recipients: Vec<PublicKey> = recipient_names
        .iter()
        .map(|name| {
            private_keys
                .get(*name)
                .map(PrivateKey::public_key)
                .ok_or_else(|| format!("unknown recipient {name}"))
        })
        .collect::<Result<_, _>>()?;
    recipients.extend_from_slice(extra_recipients);
    recipients.push(sender.public_key());
    let content = seal(text, files, CHANNEL_ID, sender, &recipients, SENT_AT)
        .map_err(|error| format!("seal {name}: {error}"))?;
    Ok(MessageVector {
        name: name.to_owned(),
        sender: sender_name.to_owned(),
        recipients: recipient_names
            .iter()
            .map(|name| (*name).to_owned())
            .collect(),
        text: text.to_owned(),
        files: files
            .iter()
            .map(|file| hex::encode(file.encode()))
            .collect(),
        content,
    })
}

fn vector_file(
    key_seed: &[u8],
    length: u32,
    width: u16,
    height: u16,
    kind: FileKind,
) -> PrivateFile {
    let key: [u8; 32] = Sha256::digest(key_seed).into();
    PrivateFile {
        key,
        length,
        sealed_length: (padme(length as usize) + 16) as u32,
        width,
        height,
        kind,
    }
}

fn vector_private_key(name: &str) -> PrivateKey {
    let seed = Sha256::digest(format!("duhcord-vector-{name}").as_bytes());
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&seed);
    PrivateKey::from_bytes(bytes)
}

fn dense_inputs() -> Vec<Vec<u8>> {
    let mut long = Sha512::digest(b"a").to_vec();
    long.extend_from_slice(&Sha512::digest(b"b")[..36]);
    vec![
        Vec::new(),
        vec![0],
        vec![0xff],
        vec![0, 1],
        vec![0xff; 4],
        (0..15).collect(),
        (0..16).collect(),
        (0..17).collect(),
        long,
    ]
}

fn check_path(path: &Path) -> Result<(), String> {
    let json = fs::read(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    let vectors: Vectors =
        serde_json::from_slice(&json).map_err(|error| format!("parse vectors: {error}"))?;
    let failures = check_vectors(&vectors);
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("\n"))
    }
}

fn check_vectors(vectors: &Vectors) -> Vec<String> {
    let mut failures = Vec::new();
    if vectors.version != 3 {
        failures.push(format!("unsupported version {}", vectors.version));
    }
    if vectors.channel_id != CHANNEL_ID_TEXT {
        failures.push(format!("unexpected channelId {}", vectors.channel_id));
    }
    let private_keys: HashMap<String, PrivateKey> = ["alice", "bob", "carol", "dave"]
        .into_iter()
        .map(|name| (name.to_owned(), vector_private_key(name)))
        .collect();
    let expected_messages = expected_messages();
    for (name, private_key) in &private_keys {
        let expected = hex::encode(private_key.public_key());
        match vectors.public_keys.get(name) {
            Some(actual) if actual == &expected => {}
            Some(actual) => failures.push(format!(
                "public key {name}: expected {expected}, got {actual}"
            )),
            None => failures.push(format!("missing public key {name}")),
        }
    }

    if vectors.messages.len() != expected_messages.len() {
        failures.push(format!(
            "expected {} messages, found {}",
            expected_messages.len(),
            vectors.messages.len()
        ));
    }
    let message_names: Vec<_> = vectors
        .messages
        .iter()
        .map(|message| message.name.as_str())
        .collect();
    let expected_message_names: Vec<_> = expected_messages
        .iter()
        .map(|message| message.name)
        .collect();
    if message_names != expected_message_names {
        failures.push("message names or ordering differ from fixed vectors".to_owned());
    }
    let random_wrong_recipient = PrivateKey::generate();
    for message in &vectors.messages {
        let Some(expected) = expected_messages
            .iter()
            .find(|expected| expected.name == message.name)
        else {
            failures.push(format!("unexpected message {}", message.name));
            continue;
        };
        if message.sender != expected.sender
            || message.recipients
                != expected
                    .recipients
                    .iter()
                    .map(|name| (*name).to_owned())
                    .collect::<Vec<_>>()
            || message.text != expected.text
            || message.files != expected.files
        {
            failures.push(format!("{}: fixed message inputs differ", message.name));
        }
        let Some(sender) = private_keys.get(&message.sender) else {
            failures.push(format!(
                "{}: unknown sender {}",
                message.name, message.sender
            ));
            continue;
        };
        let payload = match kind(&message.content) {
            Kind::Encrypted(payload) => payload,
            _ => {
                failures.push(format!(
                    "{}: content is not an encrypted message",
                    message.name
                ));
                continue;
            }
        };
        let expected_files: Vec<PrivateFile> = message
            .files
            .iter()
            .filter_map(|encoded| {
                let bytes = match hex::decode(encoded) {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        failures.push(format!("{}: invalid file hex: {error}", message.name));
                        return None;
                    }
                };
                match PrivateFile::decode(&bytes) {
                    Some(file) => Some(file),
                    None => {
                        failures.push(format!("{}: invalid file descriptor", message.name));
                        None
                    }
                }
            })
            .collect();

        for recipient_name in &message.recipients {
            let Some(recipient) = private_keys.get(recipient_name) else {
                failures.push(format!(
                    "{}: recipient {recipient_name} is not a fixed vector key",
                    message.name
                ));
                continue;
            };
            match open(
                &payload,
                CHANNEL_ID,
                recipient,
                &[sender.public_key()],
                false,
            ) {
                Some(opened) if opened.text == message.text && opened.files == expected_files => {}
                Some(_) => failures.push(format!(
                    "{}: recipient {recipient_name} got different plaintext",
                    message.name
                )),
                None => failures.push(format!(
                    "{}: recipient {recipient_name} could not open message",
                    message.name
                )),
            }
        }

        match open(&payload, CHANNEL_ID, sender, &[], true) {
            Some(opened) if opened.text == message.text && opened.files == expected_files => {}
            Some(_) => failures.push(format!("{}: sender got different plaintext", message.name)),
            None => failures.push(format!(
                "{}: sender could not open own message",
                message.name
            )),
        }

        for wrong_name in ["alice", "bob", "carol", "dave"] {
            if wrong_name == message.sender
                || message.recipients.iter().any(|name| name == wrong_name)
            {
                continue;
            }
            if let Some(wrong) = private_keys.get(wrong_name) {
                if open(&payload, CHANNEL_ID, wrong, &[sender.public_key()], false).is_some() {
                    failures.push(format!(
                        "{name}: wrong recipient {wrong_name} opened message",
                        name = message.name
                    ));
                }
            }
        }
        if open(
            &payload,
            CHANNEL_ID,
            &random_wrong_recipient,
            &[sender.public_key()],
            false,
        )
        .is_some()
        {
            failures.push(format!(
                "{}: random wrong recipient opened message",
                message.name
            ));
        }

        for index in 0..payload.len() {
            let mut tampered = payload.clone();
            tampered[index] ^= 1;
            if open(&tampered, CHANNEL_ID, sender, &[], true).is_some() {
                failures.push(format!(
                    "{}: tampering at frame byte {index} was accepted",
                    message.name
                ));
            }
        }
    }

    if vectors.file_blobs.len() != 1 {
        failures.push(format!(
            "expected 1 fileBlob vector, found {}",
            vectors.file_blobs.len()
        ));
    }
    let expected_plain: Vec<u8> = (0..=255).cycle().take(5000).collect();
    for (index, vector) in vectors.file_blobs.iter().enumerate() {
        let file = decode_file(&vector.file, &mut failures, &format!("fileBlobs[{index}]"));
        let sealed = decode_hex(
            &vector.sealed,
            &mut failures,
            &format!("fileBlobs[{index}].sealed"),
        );
        let plain = decode_hex(
            &vector.plain,
            &mut failures,
            &format!("fileBlobs[{index}].plain"),
        );
        if let (Some(file), Some(sealed), Some(plain)) = (file, sealed, plain) {
            if file.length != 5000
                || file.kind != FileKind::Png
                || file.width != 10
                || file.height != 10
                || plain != expected_plain
            {
                failures.push(format!("fileBlobs[{index}]: fixed file inputs differ"));
            }
            if open_file(&sealed, &file).as_deref() != Some(plain.as_slice()) {
                failures.push(format!(
                    "fileBlobs[{index}]: file did not open to expected bytes"
                ));
            }
        }
    }

    if vectors
        .handshakes
        .iter()
        .map(|item| item.key.as_str())
        .collect::<Vec<_>>()
        != FIXED_HANDSHAKES.map(|fixed| fixed.0)
    {
        failures.push("handshake names or ordering differ from fixed vectors".to_owned());
    }
    for (vector, &(name, wants_reply, client, host, features, accepted)) in
        vectors.handshakes.iter().zip(FIXED_HANDSHAKES.iter())
    {
        let Some(expected) = vector_handshake(name, wants_reply, client, host, features, accepted)
        else {
            failures.push(format!("handshake {name}: invalid fixed client"));
            continue;
        };
        if (
            vector.wants_reply,
            vector.client,
            vector.host,
            vector.features,
        ) != (wants_reply, client, host, features)
            || vector.accepted_key_ids != sorted_hex_ids(&expected)
        {
            failures.push(format!("handshake {name}: fields differ from fixed vector"));
        }
        if handshake_content(&expected) != vector.content {
            failures.push(format!(
                "handshake {name}: content differs from our encoding of the same fields"
            ));
        }
        match kind(&vector.content) {
            Kind::Handshake(decoded) if decoded == expected => {}
            _ => failures.push(format!("handshake {name}: decoded fields differ")),
        }
    }

    let expected_dense = dense_inputs();
    if vectors.dense_text.len() != expected_dense.len() {
        failures.push(format!(
            "expected {} denseText vectors, found {}",
            expected_dense.len(),
            vectors.dense_text.len()
        ));
    }
    for (index, vector) in vectors.dense_text.iter().enumerate() {
        let Some(bytes) = decode_hex(&vector.bytes, &mut failures, &format!("denseText[{index}]"))
        else {
            continue;
        };
        if expected_dense.get(index) != Some(&bytes) {
            failures.push(format!("denseText[{index}]: unexpected input bytes"));
        }
        if dense_text::encode(&bytes) != vector.text {
            failures.push(format!("denseText[{index}]: encoding differs"));
        }
        if dense_text::decode(&vector.text).as_deref() != Some(bytes.as_slice()) {
            failures.push(format!("denseText[{index}]: decoding differs"));
        }
    }

    let expected_padme = [
        [0, 1],
        [1, 1],
        [2, 2],
        [9, 10],
        [1000, 1024],
        [70000, 71680],
    ];
    for (index, pair) in vectors.padme.iter().enumerate() {
        if padme(pair[0]) != pair[1] {
            failures.push(format!(
                "padme[{index}]: padme({}) is {}, expected {}",
                pair[0],
                padme(pair[0]),
                pair[1]
            ));
        }
    }
    if vectors.padme != expected_padme {
        failures.push("padme vectors differ from protocol expectations".to_owned());
    }

    if vectors.safety_numbers.len() != 6 {
        failures.push(format!(
            "expected 6 safetyNumbers vectors, found {}",
            vectors.safety_numbers.len()
        ));
    }
    let safety_inputs: Vec<_> = vectors
        .safety_numbers
        .iter()
        .map(|item| {
            (
                item.a.iter().map(String::as_str).collect::<Vec<_>>(),
                item.b.iter().map(String::as_str).collect::<Vec<_>>(),
                item.a_companion
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                item.b_companion
                    .iter()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
            )
        })
        .collect();
    let expected_safety_inputs = [
        (vec!["alice"], vec!["bob"], vec![], vec![]),
        (vec!["alice", "carol"], vec!["bob"], vec![], vec![]),
        (vec!["alice"], vec!["carol"], vec![], vec!["carol"]),
        (
            vec!["alice", "bob"],
            vec!["carol", "dave"],
            vec![],
            vec!["dave"],
        ),
        (vec!["alice"], vec!["alice"], vec!["alice"], vec![]),
        (vec!["bob"], vec!["alice"], vec![], vec![]),
    ];
    if safety_inputs != expected_safety_inputs {
        failures.push("safetyNumbers inputs or ordering differ from fixed vectors".to_owned());
    }
    for (index, vector) in vectors.safety_numbers.iter().enumerate() {
        let Some(a) = public_keys_for(&vector.a, vectors, &mut failures) else {
            continue;
        };
        let Some(b) = public_keys_for(&vector.b, vectors, &mut failures) else {
            continue;
        };
        let a: Vec<_> = a
            .into_iter()
            .zip(&vector.a)
            .map(|(key, name)| {
                (
                    key,
                    if vector.a_companion.contains(name) {
                        ClientClass::Companion
                    } else {
                        ClientClass::Duhcord
                    },
                )
            })
            .collect();
        let b: Vec<_> = b
            .into_iter()
            .zip(&vector.b)
            .map(|(key, name)| {
                (
                    key,
                    if vector.b_companion.contains(name) {
                        ClientClass::Companion
                    } else {
                        ClientClass::Duhcord
                    },
                )
            })
            .collect();
        if safety_number(&a, &b) != vector.number {
            failures.push(format!("safetyNumbers[{index}]: number differs"));
        }
    }

    if let (Some(first), Some(swapped)) = (
        vectors.safety_numbers.first(),
        vectors.safety_numbers.get(5),
    ) {
        if first.number != swapped.number {
            failures.push("safetyNumbers: swapping the sides changed the number".to_owned());
        }
    }

    if vectors.key_codes.len() != 1 {
        failures.push(format!(
            "expected 1 keyCode vector, found {}",
            vectors.key_codes.len()
        ));
    }
    for (index, vector) in vectors.key_codes.iter().enumerate() {
        if vector.key != "alice" {
            failures.push(format!("keyCodes[{index}]: unexpected key {}", vector.key));
        }
        let Some(key) = public_key(&vector.key, vectors, &mut failures) else {
            continue;
        };
        if key_code(&key) != vector.code {
            failures.push(format!("keyCodes[{index}]: code differs"));
        }
    }

    if vectors
        .rejects
        .iter()
        .map(|item| item.why.as_str())
        .collect::<Vec<_>>()
        != REJECT_REASONS
    {
        failures.push("rejects differ from the required list".to_owned());
    }
    for reject in &vectors.rejects {
        if kind(&reject.content) != Kind::Plain {
            failures.push(format!("rejects: \"{}\" didn't read as plain", reject.why));
        }
    }

    failures
}

fn expected_messages() -> Vec<ExpectedMessage> {
    let first_file = vector_file(b"file-0", 1000, 640, 480, FileKind::Jpeg);
    let second_file = vector_file(b"file-1", 70_000, 1, 1, FileKind::Png);
    vec![
        ExpectedMessage {
            name: "short",
            sender: "alice",
            recipients: &["bob"],
            text: "hi".to_owned(),
            files: Vec::new(),
        },
        ExpectedMessage {
            name: "unicode",
            sender: "bob",
            recipients: &["alice"],
            text: "héllo 🙋 世界\nsecond line".to_owned(),
            files: Vec::new(),
        },
        ExpectedMessage {
            name: "compressible",
            sender: "alice",
            recipients: &["bob", "carol", "dave"],
            text: "private ".repeat(120),
            files: Vec::new(),
        },
        ExpectedMessage {
            name: "incompressible",
            sender: "carol",
            recipients: &["alice"],
            text: hex::encode(Sha512::digest(b"x")),
            files: Vec::new(),
        },
        ExpectedMessage {
            name: "files",
            sender: "alice",
            recipients: &["bob"],
            text: "two pictures".to_owned(),
            files: vec![
                hex::encode(first_file.encode()),
                hex::encode(second_file.encode()),
            ],
        },
        ExpectedMessage {
            name: "max-recipients",
            sender: "dave",
            recipients: &["alice", "bob", "carol"],
            text: "eight recipients".to_owned(),
            files: Vec::new(),
        },
    ]
}

fn public_keys_for(
    names: &[String],
    vectors: &Vectors,
    failures: &mut Vec<String>,
) -> Option<Vec<PublicKey>> {
    names
        .iter()
        .map(|name| public_key(name, vectors, failures))
        .collect()
}

fn public_key(name: &str, vectors: &Vectors, failures: &mut Vec<String>) -> Option<PublicKey> {
    let Some(hex_key) = vectors.public_keys.get(name) else {
        failures.push(format!("missing public key {name}"));
        return None;
    };
    let Ok(bytes) = hex::decode(hex_key) else {
        failures.push(format!("invalid public key hex for {name}"));
        return None;
    };
    match bytes.try_into() {
        Ok(key) => Some(key),
        Err(_) => {
            failures.push(format!("public key {name} is not 32 bytes"));
            None
        }
    }
}

fn decode_file(encoded: &str, failures: &mut Vec<String>, label: &str) -> Option<PrivateFile> {
    let bytes = decode_hex(encoded, failures, label)?;
    match PrivateFile::decode(&bytes) {
        Some(file) => Some(file),
        None => {
            failures.push(format!("{label}: invalid file descriptor"));
            None
        }
    }
}

fn decode_hex(encoded: &str, failures: &mut Vec<String>, label: &str) -> Option<Vec<u8>> {
    match hex::decode(encoded) {
        Ok(bytes) => Some(bytes),
        Err(error) => {
            failures.push(format!("{label}: invalid hex: {error}"));
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_vectors_pass_the_interop_checker() {
        let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        // The committed Rust vectors are the fixture Duhcord's Swift tests read.
        let rust_vectors =
            crate_dir.join("../../../Tests/DuhcordCoreTests/Fixtures/rust-vectors.json");
        check_path(&rust_vectors).unwrap_or_else(|error| panic!("{error}"));
    }
}
