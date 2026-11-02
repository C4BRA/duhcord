use std::time::{SystemTime, UNIX_EPOCH};

use duhcord_private_protocol::{
    self as protocol, ClientClass, Features, Handshake, Host, Kind, PrivateKey, PublicKey,
};

use crate::{
    AccountKeys, Action, ChannelId, Directory, DmInfo, Engine, MessageId, OwnMac, PeerClass,
    PeerKey, State, Trust, UserInfo, WireMessage,
};

const ME: u64 = 100;
const PEER: u64 = 200;
const CHANNEL: ChannelId = 300;

fn private(byte: u8) -> PrivateKey {
    PrivateKey::from_bytes([byte; 32])
}

fn account(user_id: u64, byte: u8) -> AccountKeys {
    AccountKeys::new(user_id, [byte; 32], [byte.wrapping_add(1); 32])
}

fn user(id: u64) -> UserInfo {
    UserInfo {
        id,
        username: format!("user-{id}"),
        global_name: None,
        avatar_url: None,
    }
}

fn dm(me: u64, peer: u64) -> DmInfo {
    DmInfo {
        channel_id: CHANNEL,
        peer: user(peer),
        me: user(me),
    }
}

fn handshake(key: PublicKey, class: ClientClass, wants_reply: bool) -> String {
    protocol::handshake_content(&Handshake {
        key,
        wants_reply,
        class,
        host: Host::Unknown,
        features: if class == ClientClass::Companion {
            Features::COMPANION_V1
        } else {
            Features::DUHCORD
        },
    })
}

fn wire(id: MessageId, author_id: u64, content: String) -> WireMessage {
    WireMessage {
        id,
        author_id,
        content,
        edited_at: None,
        attachments: Vec::new(),
    }
}

fn seed_peer(directory: &mut Directory, id: u64, key: PublicKey, trust: Trust, class: PeerClass) {
    directory.people.entry(id).or_default().push(PeerKey {
        key,
        added: 0,
        trust,
        class,
        features: if class == PeerClass::Companion {
            Features::COMPANION_V1.0
        } else {
            Features::DUHCORD.0
        },
    });
}

fn open_payload(content: &str) -> Vec<u8> {
    match protocol::kind(content) {
        Kind::Encrypted(payload) => payload,
        _ => panic!("expected encrypted content"),
    }
}

fn seconds_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[test]
fn first_duhcord_key_is_tofu_and_later_key_is_pending_until_accepted() {
    let peer = private(3);
    let next_peer = private(4);
    let account = account(ME, 1);
    let own_key = account.public_key();
    let mut engine = Engine::new(account, Directory::default());
    engine.on_dm(dm(ME, PEER));
    engine.set_private(CHANNEL, true);
    engine.on_messages(
        CHANNEL,
        vec![wire(
            1,
            PEER,
            handshake(peer.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    assert_eq!(engine.status(CHANNEL).state, State::Ready);

    engine.on_messages(
        CHANNEL,
        vec![wire(
            2,
            PEER,
            handshake(next_peer.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    assert!(engine.status(CHANNEL).new_key);
    let sealed = protocol::seal(
        "pending message",
        &[],
        CHANNEL,
        &next_peer,
        &[own_key],
        seconds_now() as u32,
    )
    .expect("sealing works");
    engine.on_messages(CHANNEL, vec![wire(3, PEER, sealed)], None, true);
    let view = engine.view(CHANNEL);
    let pending = view.iter().find(|message| message.id == 3).unwrap();
    assert_eq!(pending.text, "pending message");
    assert!(!pending.trusted);
    assert!(pending.warnings[0].contains("new key"));

    engine.reject_keys(CHANNEL, &[next_peer.public_key()]);
    assert!(engine.view(CHANNEL).iter().all(|message| message.id != 3));
    assert!(!engine.accept_keys(CHANNEL, &[next_peer.public_key()], None));
}

#[test]
fn companion_peer_key_starts_pending_even_when_it_is_the_first_key() {
    let companion = private(5);
    let mut engine = Engine::new(account(ME, 1), Directory::default());
    engine.on_dm(dm(ME, PEER));
    engine.on_messages(
        CHANNEL,
        vec![wire(
            1,
            PEER,
            handshake(companion.public_key(), ClientClass::Companion, false),
        )],
        None,
        true,
    );
    assert_eq!(engine.status(CHANNEL).state, State::Off);
    assert!(engine.status(CHANNEL).new_key);
    assert_eq!(engine.pending_keys(CHANNEL).len(), 1);
}

#[test]
fn want_reply_is_requested_until_consent_and_auto_answered_after_consent() {
    let peer = private(3);
    let mut engine = Engine::new(account(ME, 1), Directory::default());
    engine.on_dm(dm(ME, PEER));
    let actions = engine.on_messages(
        CHANNEL,
        vec![wire(
            10,
            PEER,
            handshake(peer.public_key(), ClientClass::Duhcord, true),
        )],
        None,
        true,
    );
    assert!(actions
        .iter()
        .all(|action| !matches!(action, Action::Send { .. })));
    assert_eq!(engine.status(CHANNEL).state, State::Request);

    let actions = engine.agree(CHANNEL);
    assert!(actions.iter().any(|action| {
        matches!(action, Action::Send { content, .. } if matches!(
            protocol::kind(content),
            Kind::Handshake(Handshake { wants_reply: false, .. })
        ))
    }));

    let mut unconsented = Engine::new(account(ME, 1), Directory::default());
    unconsented.on_dm(dm(ME, PEER));
    unconsented.on_messages(
        CHANNEL,
        vec![wire(
            11,
            PEER,
            handshake(peer.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    let actions = unconsented.agree(CHANNEL);
    assert!(actions.iter().any(|action| {
        matches!(action, Action::Send { content, .. } if matches!(
            protocol::kind(content),
            Kind::Handshake(Handshake { wants_reply: false, .. })
        ))
    }));

    let mut no_key = Engine::new(account(ME, 1), Directory::default());
    no_key.on_dm(dm(ME, PEER));
    let actions = no_key.agree(CHANNEL);
    assert!(actions.iter().any(|action| {
        matches!(action, Action::Send { content, .. } if matches!(
            protocol::kind(content),
            Kind::Handshake(Handshake { wants_reply: true, .. })
        ))
    }));
}

#[test]
fn label_only_weakens_and_companion_upgrade_demotes_tofu() {
    let peer = private(3);
    let mut engine = Engine::new(account(ME, 1), Directory::default());
    engine.on_dm(dm(ME, PEER));
    engine.on_messages(
        CHANNEL,
        vec![wire(
            1,
            PEER,
            handshake(peer.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    assert_eq!(engine.directory().people[&PEER][0].trust, Trust::Accepted);
    engine.on_messages(
        CHANNEL,
        vec![wire(
            2,
            PEER,
            handshake(peer.public_key(), ClientClass::Companion, false),
        )],
        None,
        true,
    );
    assert_eq!(
        engine.directory().people[&PEER][0].class,
        PeerClass::Companion
    );
    assert_eq!(engine.directory().people[&PEER][0].trust, Trust::Pending);
    engine.accept_keys(CHANNEL, &[peer.public_key()], None);
    engine.on_messages(
        CHANNEL,
        vec![wire(
            3,
            PEER,
            handshake(peer.public_key(), ClientClass::Companion, false),
        )],
        None,
        true,
    );
    assert_eq!(engine.directory().people[&PEER][0].trust, Trust::Accepted);
    engine.on_messages(
        CHANNEL,
        vec![wire(
            4,
            PEER,
            handshake(peer.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    assert_eq!(
        engine.directory().people[&PEER][0].class,
        PeerClass::Companion
    );
}

#[test]
fn replay_copy_and_timestamp_drift_are_warned() {
    let peer = private(3);
    let recipient = private(1);
    let mut directory = Directory::default();
    directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut directory,
        PEER,
        peer.public_key(),
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    let mut engine = Engine::new(AccountKeys::new(ME, [1; 32], [2; 32]), directory);
    engine.on_dm(dm(ME, PEER));
    let content = protocol::seal(
        "replayed",
        &[],
        CHANNEL,
        &peer,
        &[recipient.public_key()],
        seconds_now() as u32,
    )
    .unwrap();
    engine.on_messages(
        CHANNEL,
        vec![wire(100, PEER, content.clone()), wire(200, PEER, content)],
        None,
        true,
    );
    let views = engine.view(CHANNEL);
    assert!(views[1]
        .warnings
        .iter()
        .any(|warning| warning.contains("copy of an earlier private message")));

    let drifted = protocol::seal("old", &[], CHANNEL, &peer, &[recipient.public_key()], 1).unwrap();
    let mut old_message = wire(300, PEER, drifted);
    old_message.edited_at = Some(seconds_now());
    engine.on_messages(CHANNEL, vec![old_message], None, true);
    assert!(engine
        .view(CHANNEL)
        .iter()
        .find(|message| message.id == 300)
        .unwrap()
        .warnings
        .iter()
        .any(|warning| warning.contains("Written 00:00 UTC")));
}

#[test]
fn engines_exchange_and_open_messages_in_one_dm() {
    let alice_keys = account(ME, 1);
    let bob_keys = account(PEER, 3);
    let alice_public = alice_keys.public_key();
    let bob_public = bob_keys.public_key();

    let mut alice_directory = Directory::default();
    alice_directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut alice_directory,
        PEER,
        bob_public,
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    let mut bob_directory = Directory::default();
    bob_directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut bob_directory,
        ME,
        alice_public,
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    let mut alice = Engine::new(alice_keys, alice_directory);
    let mut bob = Engine::new(bob_keys, bob_directory);
    alice.on_dm(dm(ME, PEER));
    bob.on_dm(dm(PEER, ME));

    let Action::Send { content, .. } = alice.seal_text(CHANNEL, "hello Bob").unwrap() else {
        panic!("engine should send a sealed message");
    };
    bob.on_messages(CHANNEL, vec![wire(1, ME, content)], None, true);
    let view = bob.view(CHANNEL);
    assert_eq!(view.len(), 1);
    assert_eq!(view[0].text, "hello Bob");
    assert!(view[0].trusted);

    let Action::Send { content, .. } = bob.seal_text(CHANNEL, "hello Alice").unwrap() else {
        panic!("engine should send a sealed message");
    };
    alice.on_messages(CHANNEL, vec![wire(2, PEER, content)], None, true);
    assert_eq!(alice.view(CHANNEL)[0].text, "hello Alice");
}

#[test]
fn opens_protocol_message_from_duhcord_class_sender() {
    let peer = private(7);
    let recipient = private(1);
    let mut directory = Directory::default();
    directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut directory,
        PEER,
        peer.public_key(),
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    let mut engine = Engine::new(account(ME, 1), directory);
    engine.on_dm(dm(ME, PEER));
    let content = protocol::seal(
        "from Duhcord",
        &[],
        CHANNEL,
        &peer,
        &[recipient.public_key()],
        seconds_now() as u32,
    )
    .unwrap();
    engine.on_messages(CHANNEL, vec![wire(1, PEER, content)], None, true);
    assert_eq!(engine.view(CHANNEL)[0].text, "from Duhcord");
}

#[test]
fn own_mac_is_pending_until_approved_and_joins_recipients_and_safety_number() {
    let mac = private(8);
    let peer = private(3);
    let own = account(ME, 1);
    let own_public = own.public_key();
    let mut directory = Directory::default();
    directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut directory,
        PEER,
        peer.public_key(),
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    let mut engine = Engine::new(own, directory);
    engine.on_dm(dm(ME, PEER));

    engine.on_messages(
        CHANNEL,
        vec![wire(
            10,
            ME,
            handshake(mac.public_key(), ClientClass::Duhcord, false),
        )],
        None,
        true,
    );
    assert_eq!(engine.pending_own_macs().len(), 1);
    assert_eq!(engine.directory().own_macs[0].trust, Trust::Pending);

    assert!(engine.accept_own_mac(mac.public_key()));
    assert!(engine.pending_own_macs().is_empty());
    let Action::Send { content, .. } = engine.seal_text(CHANNEL, "for all my devices").unwrap()
    else {
        panic!("engine should send a sealed message");
    };
    let opened = protocol::open(&open_payload(&content), CHANNEL, &mac, &[own_public], false)
        .expect("the approved Mac is a recipient");
    assert_eq!(opened.text, "for all my devices");

    let expected = protocol::safety_number(
        &[
            (own_public, ClientClass::Companion),
            (mac.public_key(), ClientClass::Duhcord),
        ],
        &[(peer.public_key(), ClientClass::Duhcord)],
    );
    assert_eq!(
        engine.safety_number(CHANNEL, &[]).as_deref(),
        Some(expected.as_str())
    );
}

#[test]
fn own_account_companion_handshake_with_another_key_is_ignored() {
    let second_companion = private(12);
    let mut engine = Engine::new(account(ME, 1), Directory::default());
    engine.on_dm(dm(ME, PEER));
    engine.on_messages(
        CHANNEL,
        vec![wire(
            50,
            ME,
            handshake(second_companion.public_key(), ClientClass::Companion, false),
        )],
        None,
        true,
    );
    assert!(engine.directory().own_macs.is_empty());
    assert!(engine.pending_own_macs().is_empty());
}

#[test]
fn own_mac_approval_limit_is_three_and_pending_limit_is_four() {
    let mut engine = Engine::new(account(ME, 1), Directory::default());
    engine.on_dm(dm(ME, PEER));
    let macs: Vec<_> = (20..28).map(private).collect();
    let messages = macs[..5]
        .iter()
        .enumerate()
        .map(|(index, key)| {
            wire(
                index as u64 + 1,
                ME,
                handshake(key.public_key(), ClientClass::Duhcord, false),
            )
        })
        .collect();
    engine.on_messages(CHANNEL, messages, None, true);
    assert_eq!(engine.pending_own_macs().len(), 4);
    assert_eq!(engine.directory().own_macs.len(), 4);
    for key in &macs[..3] {
        assert!(engine.accept_own_mac(key.public_key()));
    }
    assert!(!engine.accept_own_mac(macs[3].public_key()));
}

#[test]
fn accepted_own_macs_are_deduplicated_and_recipient_cap_errors_are_surfaced() {
    let peer = private(3);
    let own_macs: Vec<_> = (20..29).map(private).collect();
    let mut directory = Directory::default();
    directory.private_channels.insert(CHANNEL);
    seed_peer(
        &mut directory,
        PEER,
        peer.public_key(),
        Trust::Accepted,
        PeerClass::Duhcord,
    );
    directory.own_macs = own_macs
        .iter()
        .map(|key| OwnMac {
            key: key.public_key(),
            added: 0,
            trust: Trust::Accepted,
        })
        .collect();
    let mut engine = Engine::new(account(ME, 1), directory);
    engine.on_dm(dm(ME, PEER));
    assert!(matches!(
        engine.seal_text(CHANNEL, "over recipient cap"),
        Err(crate::EngineError::Seal(
            protocol::SealError::TooManyRecipients
        ))
    ));
}
