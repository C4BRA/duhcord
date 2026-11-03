use std::time::{SystemTime, UNIX_EPOCH};

use duhcord_private_protocol::{ClientClass, Features, Handshake, PrivateKey};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::{net::TcpStream, sync::Mutex as AsyncMutex, time::timeout};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

use super::*;

static TEST_LOCK: AsyncMutex<()> = AsyncMutex::const_new(());

const ME: UserId = 700_000_000_000_000_001;
const PEER: UserId = 700_000_000_000_000_002;
const CHANNEL: ChannelId = 700_000_000_000_000_100;
const CANARY: &str = "canary-plaintext-🦜-must-never-cross-the-bridge";

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct Plugin {
    socket: Socket,
    /// Every frame the companion sent, as raw text, for the canary check.
    seen: Vec<String>,
    next_id: u64,
}

impl Plugin {
    async fn connect(port: u16) -> Self {
        let (socket, _) = connect_async(format!("ws://127.0.0.1:{port}/bridge"))
            .await
            .unwrap();
        let start = (now_ms() - DISCORD_EPOCH_MS) << 22;
        Self {
            socket,
            seen: Vec::new(),
            next_id: start,
        }
    }

    async fn send(&mut self, value: Value) {
        self.socket
            .send(Message::Text(value.to_string().into()))
            .await
            .unwrap();
    }

    async fn recv(&mut self) -> Value {
        loop {
            let message = timeout(Duration::from_secs(5), self.socket.next())
                .await
                .expect("companion answered in time")
                .expect("socket open")
                .expect("socket ok");
            if let Message::Text(text) = message {
                self.seen.push(text.to_string());
                return serde_json::from_str(&text).unwrap();
            }
        }
    }

    /// Next frame of type `t`, skipping status badges.
    async fn recv_type(&mut self, t: &str) -> Value {
        loop {
            let frame = self.recv().await;
            if frame["t"] == t {
                return frame;
            }
            assert_eq!(frame["t"], "status", "unexpected frame {frame}");
        }
    }

    fn snowflake(&mut self) -> String {
        self.next_id += 1 << 22;
        self.next_id.to_string()
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn temp_dir() -> PathBuf {
    std::env::temp_dir().join(format!(
        "duhcord-service-{}-{}",
        std::process::id(),
        now_ms()
    ))
}

fn message(id: &str, author: UserId, content: &str) -> Value {
    json!({"id": id, "authorId": author.to_string(), "content": content, "editedAt": null, "attachments": []})
}

async fn next_ui(
    events: &mut mpsc::UnboundedReceiver<UiEvent>,
    want: impl Fn(&UiEvent) -> bool,
) -> UiEvent {
    loop {
        let event = timeout(Duration::from_secs(5), events.recv())
            .await
            .expect("ui event in time")
            .expect("ui channel open");
        if want(&event) {
            return event;
        }
    }
}

async fn eventually(mut condition: impl FnMut() -> bool) {
    for _ in 0..250 {
        if condition() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("condition not reached in time");
}

async fn paired_plugin(service: &Service, ui: &mut mpsc::UnboundedReceiver<UiEvent>) -> Plugin {
    let mut plugin = Plugin::connect(service.bridge_port()).await;
    plugin
        .send(json!({"t":"hello","v":duhcord_companion_bridge::BRIDGE_VERSION,"host":"betterdiscord","plugin":"1.0.0","userId":ME.to_string(),"token":null}))
        .await;
    let pairing = plugin.recv_type("pairing").await;
    let UiEvent::PairingRequested(request) =
        next_ui(ui, |e| matches!(e, UiEvent::PairingRequested(_))).await
    else {
        unreachable!()
    };
    assert_eq!(request.code, pairing["code"]);
    assert_eq!(service.pending_pairings().len(), 1);
    service.approve_pairing(request.conn).unwrap();
    assert_eq!(
        plugin.recv_type("paired").await["token"]
            .as_str()
            .unwrap()
            .len(),
        43
    );
    plugin.recv_type("ready").await;
    next_ui(ui, |e| matches!(e, UiEvent::PairingResolved { .. })).await;
    assert!(service.pending_pairings().is_empty());
    plugin
}

#[tokio::test]
async fn round_trip_with_a_duhcord_peer_never_leaks_plaintext() {
    let _guard = TEST_LOCK.lock().await;
    keyring::set_default_credential_builder(keyring::mock::default_credential_builder());
    let dir = temp_dir();
    let (service, mut ui) = Service::start(&dir, BridgeConfig::default()).await.unwrap();
    let mut plugin = paired_plugin(&service, &mut ui).await;

    let accounts = service.accounts();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].hosts, vec!["betterdiscord".to_owned()]);
    assert!(accounts[0].key_code.is_some());

    // The plugin reports the DM; the companion answers with its badge.
    plugin
        .send(json!({"t":"dm","channelId":CHANNEL.to_string(),
            "peer":{"id":PEER.to_string(),"username":"peer","globalName":"Peer","avatarUrl":null},
            "me":{"id":ME.to_string(),"username":"me"}}))
        .await;
    let status = plugin.recv_type("status").await;
    assert_eq!(status["state"], "off");
    assert_eq!(service.chats(ME).unwrap().len(), 1);

    // Sending before Private is on is refused.
    assert!(service.send_text(ME, CHANNEL, CANARY).is_err());

    // Switching to Private sends our v3 handshake (asking for a reply), naming the mod.
    service.set_private(ME, CHANNEL, true).unwrap();
    let send = plugin.recv_type("send").await;
    let content = send["content"].as_str().unwrap().to_owned();
    let Kind::Handshake(ours) = protocol::kind(&content) else {
        panic!("expected a handshake, got {content}");
    };
    assert_eq!(ours.class, ClientClass::Companion);
    assert_eq!(ours.host, Host::BETTERDISCORD);
    assert!(ours.wants_reply);
    let our_id = plugin.snowflake();
    plugin
        .send(json!({"t":"sent","nonce":send["nonce"],"messageId":our_id}))
        .await;
    eventually(|| service.lock().outgoing.is_empty()).await;
    assert_eq!(service.chat(ME, CHANNEL).unwrap().status.state, "waiting");

    // The Duhcord peer answers (after accepting our key, which it lists as a receipt). Its first key is trusted on
    // first use.
    let peer_key = PrivateKey::generate();
    let peer_handshake = protocol::handshake_content(&Handshake {
        key: peer_key.public_key(),
        wants_reply: false,
        class: ClientClass::Duhcord,
        host: Host::UNKNOWN,
        features: Features::DUHCORD,
        accepted_key_ids: vec![protocol::key_id(&ours.key)],
    });
    let peer_hs_id = plugin.snowflake();
    plugin
        .send(json!({"t":"messages","channelId":CHANNEL.to_string(),
            "messages":[message(&our_id, ME, &content), message(&peer_hs_id, PEER, &peer_handshake)],
            "before":null,"exhausted":true}))
        .await;
    eventually(|| service.chat(ME, CHANNEL).unwrap().status.state == "ready").await;
    // Trusting their key changed what we count, so the companion tells them (spec §3 rule 3).
    let tell = plugin.recv_type("send").await;
    let Kind::Handshake(told) = protocol::kind(tell["content"].as_str().unwrap()) else {
        panic!("expected a handshake");
    };
    assert_eq!(
        told.accepted_key_ids,
        vec![protocol::key_id(&peer_key.public_key())]
    );
    let tell_id = plugin.snowflake();
    plugin
        .send(json!({"t":"sent","nonce":tell["nonce"],"messageId":tell_id}))
        .await;
    let chat = service.chat(ME, CHANNEL).unwrap();
    assert!(chat.can_send && chat.has_our_key);
    assert_eq!(chat.their_keys.len(), 1);
    assert_eq!(chat.our_keys.len(), 1);
    assert_eq!(chat.status.peer_class, Some("duhcord"));
    assert!(chat.safety_number.is_some());
    assert!(!chat.status.verified);

    // Text typed in the companion is sealed; only ciphertext reaches the plugin.
    service.send_text(ME, CHANNEL, CANARY).unwrap();
    let send = plugin.recv_type("send").await;
    let sealed = send["content"].as_str().unwrap().to_owned();
    let Kind::Encrypted(payload) = protocol::kind(&sealed) else {
        panic!("expected ciphertext");
    };
    let our_public = PrivateKey::from_bytes(
        *service
            .read(ME, |engine| Ok(engine.account().private_key_bytes()))
            .unwrap(),
    )
    .public_key();
    let opened = protocol::open(&payload, CHANNEL, &peer_key, &[our_public], false).unwrap();
    assert_eq!(opened.text, CANARY);

    // The peer replies; the companion shows it (and our own echoed message).
    let reply = protocol::seal(
        "hello from duhcord",
        &[],
        CHANNEL,
        &peer_key,
        &[our_public, peer_key.public_key()],
        (now_ms() / 1000) as u32,
    )
    .unwrap();
    let sent_id = plugin.snowflake();
    plugin
        .send(json!({"t":"sent","nonce":send["nonce"],"messageId":sent_id}))
        .await;
    let reply_id = plugin.snowflake();
    plugin
        .send(json!({"t":"messages","channelId":CHANNEL.to_string(),
            "messages":[message(&sent_id, ME, &sealed), message(&reply_id, PEER, &reply)],
            "before":null,"exhausted":true}))
        .await;
    eventually(|| service.chat(ME, CHANNEL).unwrap().messages.len() == 2).await;
    let chat = service.chat(ME, CHANNEL).unwrap();
    let texts: Vec<_> = chat
        .messages
        .iter()
        .map(|m| (m.from_me, m.text.as_str()))
        .collect();
    assert_eq!(texts, vec![(true, CANARY), (false, "hello from duhcord")]);
    assert!(chat
        .messages
        .iter()
        .all(|m| m.trusted && m.warnings.is_empty()));

    // Verifying flips the badge.
    service.mark_verified(ME, CHANNEL).unwrap();
    assert!(plugin.recv_type("status").await["verified"]
        .as_bool()
        .unwrap());

    // Locking drops the plaintext and tells the plugin.
    service.lock_session();
    assert_eq!(plugin.recv_type("status").await["state"], "locked");
    assert!(service.chat(ME, CHANNEL).unwrap().messages.is_empty());
    assert!(matches!(
        service.send_text(ME, CHANNEL, CANARY),
        Err(ServiceError::SessionLocked)
    ));
    service.unlock_session();
    let history = plugin.recv_type("needHistory").await;
    assert_eq!(history["before"], Value::Null);

    // The canary never crossed the bridge in any frame.
    assert!(plugin.seen.iter().all(|frame| !frame.contains(CANARY)));
    assert!(plugin
        .seen
        .iter()
        .all(|frame| !frame.contains("hello from duhcord")));

    // The directory was saved, encrypted.
    let saved = std::fs::read(dir.join("accounts").join(format!("{ME}.v3.dir"))).unwrap();
    assert!(!String::from_utf8_lossy(&saved).contains("private_channels"));

    service.shutdown().await;
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn send_failure_releases_the_handshake_and_reports_it() {
    let _guard = TEST_LOCK.lock().await;
    keyring::set_default_credential_builder(keyring::mock::default_credential_builder());
    let dir = temp_dir();
    let (service, mut ui) = Service::start(&dir, BridgeConfig::default()).await.unwrap();
    let mut plugin = paired_plugin(&service, &mut ui).await;
    plugin
        .send(json!({"t":"dm","channelId":CHANNEL.to_string(),
            "peer":{"id":PEER.to_string(),"username":"peer"},
            "me":{"id":ME.to_string(),"username":"me"}}))
        .await;
    plugin.recv_type("status").await;

    service.set_private(ME, CHANNEL, true).unwrap();
    let send = plugin.recv_type("send").await;
    plugin
        .send(json!({"t":"sendFailed","nonce":send["nonce"],"error":"rate-limited"}))
        .await;
    let failed = next_ui(&mut ui, |e| matches!(e, UiEvent::SendFailed { .. })).await;
    assert_eq!(
        failed,
        UiEvent::SendFailed {
            user_id: ME.to_string(),
            channel_id: CHANNEL.to_string(),
            error: "rate-limited".to_owned()
        }
    );

    // Turning Private off and on again retries the handshake, since it's no longer in flight.
    service.set_private(ME, CHANNEL, false).unwrap();
    service.set_private(ME, CHANNEL, true).unwrap();
    let retry = plugin.recv_type("send").await;
    assert!(matches!(
        protocol::kind(retry["content"].as_str().unwrap()),
        Kind::Handshake(_)
    ));

    // A DM claimed for another account is ignored.
    plugin
        .send(json!({"t":"dm","channelId":"5","peer":{"id":"6","username":"x"},"me":{"id":"7","username":"y"}}))
        .await;
    plugin
        .send(json!({"t":"open","channelId":CHANNEL.to_string()}))
        .await;
    next_ui(&mut ui, |e| matches!(e, UiEvent::OpenChat { .. })).await;
    assert_eq!(service.chats(ME).unwrap().len(), 1);

    // Disconnecting makes sending fail cleanly.
    drop(plugin);
    eventually(|| service.accounts()[0].hosts.is_empty()).await;
    assert!(matches!(
        service.send_text(ME, CHANNEL, "x"),
        Err(ServiceError::NotConnected)
    ));
    service.shutdown().await;
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn media_urls_and_image_types_are_checked() {
    let ok = url::Url::parse("https://cdn.discordapp.com/attachments/1/2/encrypted.bin").unwrap();
    assert!(allowed_media_url(&ok));
    for bad in [
        "http://cdn.discordapp.com/a",
        "https://cdn.discordapp.com:8443/a",
        "https://user@cdn.discordapp.com/a",
        "https://evil.example/a",
        "https://cdn.discordapp.com.evil.example/a",
    ] {
        assert!(!allowed_media_url(&url::Url::parse(bad).unwrap()), "{bad}");
    }

    let png = b"\x89PNG\r\n\x1a\nrest-of-image".to_vec();
    let (file, sealed) = protocol::seal_file(&png, 4, 4, FileKind::Png).unwrap();
    let image = decrypt_image(&sealed, &file).unwrap();
    assert_eq!(image.mime, "image/png");
    assert_eq!(&*image.bytes, &png);

    let (wrong, sealed) = protocol::seal_file(b"not a jpeg", 4, 4, FileKind::Jpeg).unwrap();
    assert!(decrypt_image(&sealed, &wrong).is_err());
}

#[tokio::test]
async fn an_outdated_plugin_is_turned_away_and_reported() {
    let _guard = TEST_LOCK.lock().await;
    keyring::set_default_credential_builder(keyring::mock::default_credential_builder());
    let dir = temp_dir();
    let (service, mut ui) = Service::start(&dir, BridgeConfig::default()).await.unwrap();
    let mut old = Plugin::connect(service.bridge_port()).await;
    old.send(json!({"t":"hello","v":1,"host":"betterdiscord","plugin":"0.1.0","userId":ME.to_string(),"token":null}))
        .await;
    assert_eq!(old.recv().await["code"], "plugin-outdated");
    next_ui(&mut ui, |e| matches!(e, UiEvent::AccountsChanged)).await;
    assert_eq!(
        service.outdated_plugins(),
        vec![OutdatedPlugin {
            host: "betterdiscord".to_owned(),
            plugin_version: Some("0.1.0".to_owned()),
            plugin_outdated: true,
        }]
    );
    // Once an up-to-date plugin of the same mod connects, the warning goes away.
    let _new = paired_plugin(&service, &mut ui).await;
    assert!(service.outdated_plugins().is_empty());
    service.shutdown().await;
    let _ = std::fs::remove_dir_all(dir);
}
