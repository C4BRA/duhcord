use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpListener},
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::{net::TcpStream, sync::Mutex};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{
        client::IntoClientRequest,
        http::{header, HeaderValue},
        protocol::Message,
    },
    MaybeTlsStream, WebSocketStream,
};

use super::*;

static TEST_LOCK: Mutex<()> = Mutex::const_new(());

type ClientSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

fn test_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "duhcord-bridge-{label}-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ))
}

async fn start(
    label: &str,
) -> (
    BridgeHandle,
    tokio::sync::mpsc::UnboundedReceiver<BridgeEvent>,
    PathBuf,
) {
    let path = test_dir(label);
    std::fs::create_dir_all(&path).unwrap();
    let (handle, events) = Bridge::start(&path, BridgeConfig::default()).await.unwrap();
    (handle, events, path)
}

async fn connect(
    handle: &BridgeHandle,
    origin: Option<&str>,
    host: Option<&str>,
) -> Option<ClientSocket> {
    let mut request = format!("ws://127.0.0.1:{}/", handle.local_addr().port())
        .into_client_request()
        .unwrap();
    if let Some(origin) = origin {
        request
            .headers_mut()
            .insert(header::ORIGIN, HeaderValue::from_str(origin).unwrap());
    }
    if let Some(host) = host {
        request
            .headers_mut()
            .insert(header::HOST, HeaderValue::from_str(host).unwrap());
    }
    connect_async(request).await.ok().map(|(socket, _)| socket)
}

async fn send_json(socket: &mut ClientSocket, frame: Value) {
    socket
        .send(Message::Text(frame.to_string().into()))
        .await
        .unwrap();
}

async fn next_json(socket: &mut ClientSocket) -> Option<Value> {
    loop {
        match socket.next().await? {
            Ok(Message::Text(text)) => return serde_json::from_str(&text).ok(),
            Ok(Message::Close(_)) | Err(_) => return None,
            Ok(Message::Ping(bytes)) => {
                socket.send(Message::Pong(bytes)).await.ok()?;
            }
            Ok(Message::Pong(_) | Message::Binary(_) | Message::Frame(_)) => {}
        }
    }
}

fn hello(token: Option<&str>) -> Value {
    json!({
        "t": "hello",
        "v": 1,
        "host": "vencord",
        "plugin": "1.0.0",
        "userId": "123456789",
        "token": token
    })
}

async fn pairing_requested(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<BridgeEvent>,
) -> (ConnectionId, String) {
    loop {
        match events.recv().await.unwrap() {
            BridgeEvent::PairingRequested {
                conn,
                code,
                host,
                user_id,
            } => {
                assert_eq!(host, "vencord");
                assert_eq!(user_id, 123456789);
                assert_eq!(code.len(), 6);
                assert!(code.chars().all(|digit| digit.is_ascii_digit()));
                return (conn, code);
            }
            BridgeEvent::Ready { .. } | BridgeEvent::Disconnected { .. } => {}
            _ => panic!("unexpected bridge event"),
        }
    }
}

async fn approve(
    handle: &BridgeHandle,
    events: &mut tokio::sync::mpsc::UnboundedReceiver<BridgeEvent>,
    socket: &mut ClientSocket,
) -> Vec<u8> {
    let (conn, code) = pairing_requested(events).await;
    let pairing = next_json(socket).await.unwrap();
    assert_eq!(pairing["t"], "pairing");
    assert_eq!(pairing["code"], code);
    handle.approve_pairing(conn).unwrap();
    let paired = next_json(socket).await.unwrap();
    assert_eq!(paired["t"], "paired");
    let token = URL_SAFE_NO_PAD
        .decode(paired["token"].as_str().unwrap())
        .unwrap();
    let ready = next_json(socket).await.unwrap();
    assert_eq!(ready["t"], "ready");
    token
}

#[test]
fn outgoing_send_and_edit_require_protocol_content() {
    assert!(matches!(
        validate_frame(&CompanionFrame::Send {
            nonce: "1".to_owned(),
            channel_id: 2,
            content: "not encrypted".to_owned(),
        }),
        Err(BridgeError::NotPrivate)
    ));
    assert!(validate_frame(&CompanionFrame::Delete {
        nonce: "1".to_owned(),
        channel_id: 2,
        message_id: 3,
    })
    .is_ok());
}

#[tokio::test]
async fn bad_origin_closes_with_policy_and_bad_host_is_rejected() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, _events, path) = start("origin").await;
    let mut socket = connect(&handle, Some("https://evil.example"), None)
        .await
        .unwrap();
    match socket.next().await.unwrap().unwrap() {
        Message::Close(Some(frame)) => assert_eq!(frame.code, CloseCode::Policy),
        message => panic!("expected policy close, got {message:?}"),
    }
    assert!(connect(&handle, None, Some("example.com:47823"))
        .await
        .is_none());
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn unpaired_frames_receive_error_and_unknown_types_are_ignored_after_pairing() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, mut events, path) = start("unpaired").await;
    let mut socket = connect(&handle, None, None).await.unwrap();
    send_json(&mut socket, json!({"t":"dm"})).await;
    assert_eq!(next_json(&mut socket).await.unwrap()["code"], "unpaired");

    send_json(&mut socket, hello(None)).await;
    let token = approve(&handle, &mut events, &mut socket).await;
    assert_eq!(token.len(), 32);
    assert!(matches!(
        events.recv().await.unwrap(),
        BridgeEvent::Ready { .. }
    ));
    send_json(&mut socket, json!({"t":"unknown-frame"})).await;
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(100), events.recv())
            .await
            .is_err()
    );
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn approved_pairing_token_works_on_reconnect_and_revocation_rejects_it() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, mut events, path) = start("pairing").await;
    let mut first = connect(&handle, None, None).await.unwrap();
    send_json(&mut first, hello(None)).await;
    let token = approve(&handle, &mut events, &mut first).await;
    first.close(None).await.unwrap();

    let token_string = URL_SAFE_NO_PAD.encode(&token);
    let mut reconnected = connect(&handle, None, None).await.unwrap();
    send_json(&mut reconnected, hello(Some(&token_string))).await;
    assert_eq!(next_json(&mut reconnected).await.unwrap()["t"], "ready");

    let token_hash = Store::pairing_hash(&token);
    assert!(handle.revoke(token_hash).unwrap());
    assert!(reconnected.next().await.is_some());

    let mut revoked = connect(&handle, None, None).await.unwrap();
    send_json(&mut revoked, hello(Some(&token_string))).await;
    assert_eq!(next_json(&mut revoked).await.unwrap()["t"], "pairing");
    let _ = pairing_requested(&mut events).await;

    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn oversized_text_frame_closes_the_connection() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, _events, path) = start("oversized").await;
    let mut socket = connect(&handle, None, None).await.unwrap();
    // The bridge may close the connection while the oversized frame is still being written, so the send itself can
    // fail with a broken pipe or reset. That's the behaviour under test, not a failure.
    let sent = socket
        .send(Message::Text("x".repeat(MAX_FRAME_SIZE + 1).into()))
        .await;
    if sent.is_ok() {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
            .await
            .unwrap();
        assert!(matches!(
            frame,
            Some(Ok(Message::Close(_))) | Some(Err(_)) | None
        ));
    }
    // Either way, the bridge must not still be accepting frames on this connection.
    let after = socket.send(Message::Text("{}".into())).await;
    let next = tokio::time::timeout(std::time::Duration::from_secs(2), socket.next()).await;
    assert!(
        after.is_err()
            || matches!(
                next,
                Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_))))
            ),
        "connection stayed open after an oversized frame"
    );
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn bridge_binds_only_loopback_and_falls_back_when_default_port_is_busy() {
    let _guard = TEST_LOCK.lock().await;
    let blocked = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 47_823))).unwrap();
    let (handle, _events, path) = start("fallback").await;
    assert_eq!(handle.local_addr().ip(), IpAddr::V4(Ipv4Addr::LOCALHOST));
    assert!(handle.local_addr().port() > 47_823);
    assert!(handle.local_addr().port() <= 47_827);
    let config: Value =
        serde_json::from_slice(&std::fs::read(path.join("bridge.json")).unwrap()).unwrap();
    assert_eq!(config["port"], handle.local_addr().port());
    assert_eq!(config["version"], 1);
    drop(blocked);
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn ten_bad_frames_close_the_connection() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, _events, path) = start("bad-frames").await;
    let mut socket = connect(&handle, None, None).await.unwrap();
    let mut closed = false;
    for _ in 0..10 {
        socket
            .send(Message::Text("{".to_owned().into()))
            .await
            .unwrap();
        if next_json(&mut socket).await.is_none() {
            closed = true;
            break;
        }
    }
    assert!(
        closed
            || matches!(
                socket.next().await,
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None
            )
    );
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}

#[tokio::test]
async fn mismatched_bridge_versions_say_which_side_to_update() {
    let _guard = TEST_LOCK.lock().await;
    let (handle, _events, path) = start("versions").await;
    for (version, code) in [(0, "plugin-outdated"), (2, "companion-outdated")] {
        let mut socket = connect(&handle, None, None).await.unwrap();
        let mut frame = hello(None);
        frame["v"] = json!(version);
        send_json(&mut socket, frame).await;
        assert_eq!(next_json(&mut socket).await.unwrap()["code"], code);
        assert!(
            next_json(&mut socket).await.is_none(),
            "connection should close"
        );
    }
    handle.shutdown().await;
    std::fs::remove_dir_all(path).unwrap();
}
