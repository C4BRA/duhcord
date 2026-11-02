#![forbid(unsafe_code)]

use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::Path,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use duhcord_companion_engine::{
    AttachmentInfo, ChannelId, DmInfo, MessageId, UserId, UserInfo, WireMessage,
};
use duhcord_companion_store::{Store, StoreError};
use duhcord_private_protocol::{self as protocol, Kind};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use thiserror::Error;
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, watch},
};
use tokio_tungstenite::{
    accept_hdr_async_with_config,
    tungstenite::{
        handshake::server::{Request, Response},
        protocol::{frame::coding::CloseCode, CloseFrame, WebSocketConfig},
        Error as WebSocketError, Message,
    },
    WebSocketStream,
};

const PORT_START: u16 = 47_823;
const PORT_END: u16 = 47_827;
const MAX_FRAME_SIZE: usize = 1024 * 1024;
const MAX_CONNECTIONS: usize = 8;
const MAX_FRAMES_PER_SECOND: usize = 200;
const ALLOWED_ORIGINS: [&str; 3] = [
    "https://discord.com",
    "https://ptb.discord.com",
    "https://canary.discord.com",
];

pub type ConnectionId = u64;

#[derive(Clone)]
pub struct BridgeConfig {
    pub companion_version: String,
}

impl Default for BridgeConfig {
    fn default() -> Self {
        Self {
            companion_version: "1.0.0".to_owned(),
        }
    }
}

pub enum CompanionFrame {
    Send {
        nonce: String,
        channel_id: ChannelId,
        content: String,
    },
    Edit {
        nonce: String,
        channel_id: ChannelId,
        message_id: MessageId,
        content: String,
    },
    Delete {
        nonce: String,
        channel_id: ChannelId,
        message_id: MessageId,
    },
    NeedHistory {
        channel_id: ChannelId,
        before: Option<MessageId>,
    },
    Status {
        channel_id: ChannelId,
        state: String,
        verified: bool,
        new_key: bool,
        peer_class: Option<String>,
    },
}

pub enum BridgeEvent {
    PairingRequested {
        conn: ConnectionId,
        host: String,
        user_id: UserId,
        code: String,
    },
    Ready {
        conn: ConnectionId,
        user_id: UserId,
        host: String,
    },
    Dm {
        conn: ConnectionId,
        info: DmInfo,
    },
    Messages {
        conn: ConnectionId,
        channel: ChannelId,
        messages: Vec<WireMessage>,
        before: Option<MessageId>,
        exhausted: bool,
    },
    Deleted {
        conn: ConnectionId,
        channel: ChannelId,
        ids: Vec<MessageId>,
    },
    Open {
        conn: ConnectionId,
        channel: ChannelId,
    },
    Sent {
        conn: ConnectionId,
        nonce: String,
        message_id: MessageId,
    },
    SendFailed {
        conn: ConnectionId,
        nonce: String,
        error: String,
    },
    Disconnected {
        conn: ConnectionId,
        user_id: Option<UserId>,
    },
}

#[derive(Debug, Error)]
pub enum BridgeError {
    #[error("bridge I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("pairing store failed: {0}")]
    Store(#[from] StoreError),
    #[error("no available bridge port in 47823-47827")]
    NoPort,
    #[error("connection is not available")]
    NoConnection,
    #[error("connection is not paired")]
    NotReady,
    #[error("only handshake and encrypted content may be sent")]
    NotPrivate,
    #[error("bridge command channel is closed")]
    Closed,
}

struct Connection {
    user_id: Option<UserId>,
    ready: bool,
    pairing_pending: bool,
    token_hash: Option<[u8; 32]>,
    commands: mpsc::UnboundedSender<ConnectionCommand>,
}

enum ConnectionCommand {
    Approve,
    Deny,
    Frame(CompanionFrame),
    Revoke,
}

pub struct BridgeHandle {
    local_addr: SocketAddr,
    connections: Arc<Mutex<HashMap<ConnectionId, Connection>>>,
    store: Arc<Store>,
    shutdown: watch::Sender<bool>,
    shutdown_done: watch::Receiver<bool>,
}

impl Clone for BridgeHandle {
    fn clone(&self) -> Self {
        Self {
            local_addr: self.local_addr,
            connections: Arc::clone(&self.connections),
            store: Arc::clone(&self.store),
            shutdown: self.shutdown.clone(),
            shutdown_done: self.shutdown_done.clone(),
        }
    }
}

impl BridgeHandle {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn approve_pairing(&self, conn: ConnectionId) -> Result<(), BridgeError> {
        let connections = lock_connections(&self.connections);
        let connection = connections.get(&conn).ok_or(BridgeError::NoConnection)?;
        if !connection.pairing_pending {
            return Err(BridgeError::NotReady);
        }
        connection
            .commands
            .send(ConnectionCommand::Approve)
            .map_err(|_| BridgeError::Closed)
    }

    pub fn deny_pairing(&self, conn: ConnectionId) -> Result<(), BridgeError> {
        let connections = lock_connections(&self.connections);
        let connection = connections.get(&conn).ok_or(BridgeError::NoConnection)?;
        if !connection.pairing_pending {
            return Err(BridgeError::NotReady);
        }
        connection
            .commands
            .send(ConnectionCommand::Deny)
            .map_err(|_| BridgeError::Closed)
    }

    pub fn send(&self, conn: ConnectionId, frame: CompanionFrame) -> Result<(), BridgeError> {
        validate_frame(&frame)?;
        let connections = lock_connections(&self.connections);
        let connection = connections.get(&conn).ok_or(BridgeError::NoConnection)?;
        if !connection.ready {
            return Err(BridgeError::NotReady);
        }
        connection
            .commands
            .send(ConnectionCommand::Frame(frame))
            .map_err(|_| BridgeError::Closed)
    }

    pub fn send_user(&self, user_id: UserId, frame: CompanionFrame) -> Result<usize, BridgeError> {
        validate_frame(&frame)?;
        let connections = lock_connections(&self.connections);
        let mut sent = 0;
        for connection in connections
            .values()
            .filter(|connection| connection.ready && connection.user_id == Some(user_id))
        {
            connection
                .commands
                .send(ConnectionCommand::Frame(clone_frame(&frame)))
                .map_err(|_| BridgeError::Closed)?;
            sent += 1;
        }
        Ok(sent)
    }

    pub fn revoke(&self, token_hash: [u8; 32]) -> Result<bool, BridgeError> {
        let revoked = self.store.revoke_pairing(&token_hash)?;
        let connections = lock_connections(&self.connections);
        for connection in connections.values() {
            if connection.token_hash == Some(token_hash) {
                let _ = connection.commands.send(ConnectionCommand::Revoke);
            }
        }
        Ok(revoked)
    }

    pub async fn shutdown(&self) {
        let _ = self.shutdown.send(true);
        {
            let connections = lock_connections(&self.connections);
            for connection in connections.values() {
                let _ = connection.commands.send(ConnectionCommand::Revoke);
            }
        }
        let mut done = self.shutdown_done.clone();
        if !*done.borrow() {
            let _ = done.changed().await;
        }
    }
}

pub struct Bridge;

impl Bridge {
    pub async fn start(
        config_dir: impl AsRef<Path>,
        config: BridgeConfig,
    ) -> Result<(BridgeHandle, mpsc::UnboundedReceiver<BridgeEvent>), BridgeError> {
        let config_dir = config_dir.as_ref();
        let store = Arc::new(Store::open(config_dir)?);
        let (listener, local_addr) = bind_listener().await?;
        let config_file = json!({"port": local_addr.port(), "version": 1});
        std::fs::write(
            config_dir.join("bridge.json"),
            serde_json::to_vec(&config_file).expect("bridge config serializes"),
        )?;
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let (shutdown_done_tx, shutdown_done_rx) = watch::channel(false);
        let connections = Arc::new(Mutex::new(HashMap::new()));
        let next_connection = Arc::new(AtomicU64::new(1));
        let active_connections = Arc::new(AtomicUsize::new(0));
        let handle = BridgeHandle {
            local_addr,
            connections: Arc::clone(&connections),
            store: Arc::clone(&store),
            shutdown: shutdown_tx,
            shutdown_done: shutdown_done_rx,
        };
        let accept_handle = handle.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    changed = shutdown_rx.changed() => {
                        if changed.is_err() || *shutdown_rx.borrow() {
                            break;
                        }
                    }
                    accepted = listener.accept() => {
                        let Ok((stream, remote_addr)) = accepted else {
                            continue;
                        };
                        if active_connections.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
                            active_connections.fetch_sub(1, Ordering::AcqRel);
                            drop(stream);
                            continue;
                        }
                        let conn = next_connection.fetch_add(1, Ordering::Relaxed);
                        let connection_handle = accept_handle.clone();
                        let permit = ConnectionPermit(Arc::clone(&active_connections));
                        let event_tx = event_tx.clone();
                        let config = config.clone();
                        tokio::spawn(async move {
                            handle_connection(
                                connection_handle,
                                conn,
                                stream,
                                remote_addr,
                                permit,
                                config,
                                event_tx,
                            )
                            .await;
                        });
                    }
                }
            }
            let _ = shutdown_done_tx.send(true);
        });
        Ok((handle, event_rx))
    }
}

async fn bind_listener() -> Result<(TcpListener, SocketAddr), BridgeError> {
    for port in PORT_START..=PORT_END {
        match TcpListener::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)).await {
            Ok(listener) => {
                let address = listener.local_addr()?;
                return Ok((listener, address));
            }
            Err(_) => continue,
        }
    }
    Err(BridgeError::NoPort)
}

#[allow(clippy::result_large_err)]
async fn handle_connection(
    handle: BridgeHandle,
    conn: ConnectionId,
    stream: TcpStream,
    _remote_addr: SocketAddr,
    _permit: ConnectionPermit,
    config: BridgeConfig,
    event_tx: mpsc::UnboundedSender<BridgeEvent>,
) {
    let origin_allowed = Arc::new(Mutex::new(true));
    let origin_status = Arc::clone(&origin_allowed);
    let port = handle.local_addr.port();
    let callback = move |request: &Request, response: Response| {
        let host_valid = request
            .headers()
            .get("host")
            .and_then(|value| value.to_str().ok())
            .is_some_and(|host| {
                host == format!("127.0.0.1:{port}") || host == format!("localhost:{port}")
            });
        if !host_valid {
            return Err(Response::builder()
                .status(403)
                .body(Some("Host must be localhost".to_owned()))
                .expect("valid rejection response"));
        }
        let origin_valid = request.headers().get("origin").is_none_or(|value| {
            value
                .to_str()
                .is_ok_and(|origin| ALLOWED_ORIGINS.contains(&origin))
        });
        *origin_status
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = origin_valid;
        Ok(response)
    };
    let mut ws_config = WebSocketConfig::default();
    ws_config.max_message_size = Some(MAX_FRAME_SIZE);
    ws_config.max_frame_size = Some(MAX_FRAME_SIZE);
    let Ok(mut socket) = accept_hdr_async_with_config(stream, callback, Some(ws_config)).await
    else {
        return;
    };
    if !*origin_allowed
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
    {
        close_socket(&mut socket, CloseCode::Policy, "origin not allowed").await;
        return;
    }

    let (command_tx, mut command_rx) = mpsc::unbounded_channel();
    lock_connections(&handle.connections).insert(
        conn,
        Connection {
            user_id: None,
            ready: false,
            pairing_pending: false,
            token_hash: None,
            commands: command_tx,
        },
    );
    let mut user_id = None;
    let mut host = None;
    let mut ready = false;
    let mut pairing_requested = false;
    let mut bad_frames = 0usize;
    let mut window_start = Instant::now();
    let mut frame_count = 0usize;

    loop {
        tokio::select! {
            incoming = socket.next() => {
                let Some(incoming) = incoming else { break };
                let message = match incoming {
                    Ok(message) => message,
                    Err(WebSocketError::Capacity(_)) => {
                        close_socket(&mut socket, CloseCode::Size, "frame too large").await;
                        break;
                    }
                    Err(_) => break,
                };
                match message {
                    Message::Text(text) => {
                        if text.len() > MAX_FRAME_SIZE {
                            close_socket(&mut socket, CloseCode::Size, "frame too large").await;
                            break;
                        }
                        if window_start.elapsed() >= Duration::from_secs(1) {
                            window_start = Instant::now();
                            frame_count = 0;
                        }
                        frame_count += 1;
                        if frame_count > MAX_FRAMES_PER_SECOND {
                            close_socket(&mut socket, CloseCode::Policy, "rate limit exceeded").await;
                            break;
                        }
                        let Ok(value) = serde_json::from_str::<Value>(&text) else {
                            bad_frames += 1;
                            if send_json(&mut socket, json!({"t":"error","code":"bad-frame"})).await.is_err()
                                || bad_frames >= 10
                            {
                                close_socket(&mut socket, CloseCode::Policy, "too many bad frames").await;
                                break;
                            }
                            continue;
                        };
                        let Some(frame_type) = value.get("t").and_then(Value::as_str) else {
                            bad_frames += 1;
                            if send_json(&mut socket, json!({"t":"error","code":"bad-frame"})).await.is_err()
                                || bad_frames >= 10
                            {
                                close_socket(&mut socket, CloseCode::Policy, "too many bad frames").await;
                                break;
                            }
                            continue;
                        };
                        if !ready && frame_type != "hello" {
                            if send_json(&mut socket, json!({"t":"error","code":"unpaired"})).await.is_err() {
                                break;
                            }
                            continue;
                        }
                        if !ready && frame_type == "hello" {
                            if pairing_requested {
                                if send_json(&mut socket, json!({"t":"error","code":"bad-frame"})).await.is_err() {
                                    break;
                                }
                                bad_frames += 1;
                                continue;
                            }
                            match parse_hello(&value) {
                                Some(hello) => {
                                    user_id = Some(hello.user_id);
                                    host = Some(hello.host.clone());
                                    let valid_token = hello.token.as_deref().and_then(decode_token);
                                    if let Some(token) = valid_token {
                                        match handle.store.has_pairing(&token, &hello.host, hello.user_id) {
                                            Ok(true) => {
                                                ready = true;
                                                let token_hash = Some(Store::pairing_hash(&token));
                                                update_connection(&handle, conn, |entry| {
                                                    entry.user_id = user_id;
                                                    entry.ready = true;
                                                    entry.token_hash = token_hash;
                                                });
                                                let _ = send_json(&mut socket, json!({"t":"ready","userId":hello.user_id.to_string(),"companion":config.companion_version})).await;
                                                let _ = event_tx.send(BridgeEvent::Ready {
                                                    conn,
                                                    user_id: hello.user_id,
                                                    host: hello.host,
                                                });
                                            }
                                            Ok(false) | Err(_) => {
                                                begin_pairing(
                                                    &handle,
                                                    conn,
                                                    hello.host,
                                                    hello.user_id,
                                                    &mut pairing_requested,
                                                    &mut socket,
                                                    &event_tx,
                                                )
                                                .await;
                                            }
                                        }
                                    } else {
                                        begin_pairing(
                                            &handle,
                                            conn,
                                            hello.host,
                                            hello.user_id,
                                            &mut pairing_requested,
                                            &mut socket,
                                            &event_tx,
                                        )
                                        .await;
                                    }
                                }
                                None => {
                                    bad_frames += 1;
                                    if send_json(&mut socket, json!({"t":"error","code":"bad-frame"})).await.is_err()
                                        || bad_frames >= 10
                                    {
                                        close_socket(&mut socket, CloseCode::Policy, "too many bad frames").await;
                                        break;
                                    }
                                }
                            }
                            continue;
                        }

                        if !dispatch_plugin_frame(
                            frame_type,
                            &value,
                            conn,
                            &mut socket,
                            &event_tx,
                            &mut bad_frames,
                        )
                        .await
                            && bad_frames >= 10
                        {
                            close_socket(&mut socket, CloseCode::Policy, "too many bad frames").await;
                            break;
                        }
                    }
                    Message::Binary(_) => {
                        bad_frames += 1;
                        if send_json(&mut socket, json!({"t":"error","code":"bad-frame"})).await.is_err()
                            || bad_frames >= 10
                        {
                            close_socket(&mut socket, CloseCode::Policy, "too many bad frames").await;
                            break;
                        }
                    }
                    Message::Close(_) => break,
                    Message::Ping(bytes) => {
                        if socket.send(Message::Pong(bytes)).await.is_err() {
                            break;
                        }
                    }
                    Message::Pong(_) => {}
                    Message::Frame(_) => {}
                }
            }
            command = command_rx.recv() => {
                let Some(command) = command else {
                    break;
                };
                match command {
                    ConnectionCommand::Approve if pairing_requested && !ready => {
                        let Some(host_value) = host.clone() else { continue };
                        let Some(user_value) = user_id else { continue };
                        let mut token = [0u8; 32];
                        if getrandom::fill(&mut token).is_err() {
                            let _ = send_json(&mut socket, json!({"t":"error","code":"denied"})).await;
                            continue;
                        }
                        let token_string = URL_SAFE_NO_PAD.encode(token);
                        if handle.store.add_pairing(&token, &host_value, user_value).is_err() {
                            let _ = send_json(&mut socket, json!({"t":"error","code":"denied"})).await;
                            continue;
                        }
                        let token_hash = Some(Store::pairing_hash(&token));
                        ready = true;
                        pairing_requested = false;
                        update_connection(&handle, conn, |entry| {
                            entry.ready = true;
                            entry.pairing_pending = false;
                            entry.token_hash = token_hash;
                        });
                        let _ = send_json(&mut socket, json!({"t":"paired","token":token_string})).await;
                        let _ = send_json(&mut socket, json!({"t":"ready","userId":user_value.to_string(),"companion":config.companion_version})).await;
                        let _ = event_tx.send(BridgeEvent::Ready {
                            conn,
                            user_id: user_value,
                            host: host_value,
                        });
                    }
                    ConnectionCommand::Deny if pairing_requested => {
                        let _ = send_json(&mut socket, json!({"t":"error","code":"denied"})).await;
                        close_socket(&mut socket, CloseCode::Policy, "pairing denied").await;
                        break;
                    }
                    ConnectionCommand::Frame(frame) if ready => {
                        if send_json(&mut socket, frame_value(&frame)).await.is_err() {
                            break;
                        }
                    }
                    ConnectionCommand::Revoke => {
                        close_socket(&mut socket, CloseCode::Policy, "pairing revoked").await;
                        break;
                    }
                    ConnectionCommand::Approve | ConnectionCommand::Deny | ConnectionCommand::Frame(_) => {}
                }
            }
        }
    }
    lock_connections(&handle.connections).remove(&conn);
    let _ = event_tx.send(BridgeEvent::Disconnected { conn, user_id });
}

async fn begin_pairing(
    handle: &BridgeHandle,
    conn: ConnectionId,
    host: String,
    user_id: UserId,
    requested: &mut bool,
    socket: &mut WebSocketStream<TcpStream>,
    events: &mpsc::UnboundedSender<BridgeEvent>,
) {
    let code = pairing_code();
    *requested = true;
    update_connection(handle, conn, |entry| {
        entry.user_id = Some(user_id);
        entry.pairing_pending = true;
    });
    let _ = send_json(socket, json!({"t":"pairing","code":code})).await;
    let _ = events.send(BridgeEvent::PairingRequested {
        conn,
        host,
        user_id,
        code,
    });
}

async fn dispatch_plugin_frame(
    frame_type: &str,
    value: &Value,
    conn: ConnectionId,
    socket: &mut WebSocketStream<TcpStream>,
    events: &mpsc::UnboundedSender<BridgeEvent>,
    bad_frames: &mut usize,
) -> bool {
    let event = match frame_type {
        "dm" => parse_dm(value).map(|info| BridgeEvent::Dm { conn, info }),
        "messages" => parse_messages(value).map(|(channel, messages, before, exhausted)| {
            BridgeEvent::Messages {
                conn,
                channel,
                messages,
                before,
                exhausted,
            }
        }),
        "deleted" => {
            parse_deleted(value).map(|(channel, ids)| BridgeEvent::Deleted { conn, channel, ids })
        }
        "open" => parse_channel(value).map(|channel| BridgeEvent::Open { conn, channel }),
        "sent" => parse_sent(value).map(|(nonce, message_id)| BridgeEvent::Sent {
            conn,
            nonce,
            message_id,
        }),
        "sendFailed" => parse_send_failed(value).map(|(nonce, error)| BridgeEvent::SendFailed {
            conn,
            nonce,
            error,
        }),
        _ => return true,
    };
    let Some(event) = event else {
        *bad_frames += 1;
        let _ = send_json(socket, json!({"t":"error","code":"bad-frame"})).await;
        return false;
    };
    let _ = events.send(event);
    true
}

struct Hello {
    host: String,
    user_id: UserId,
    token: Option<String>,
}

fn parse_hello(value: &Value) -> Option<Hello> {
    if value.get("v").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let host = value.get("host")?.as_str()?;
    if !matches!(host, "vencord" | "vesktop" | "replugged" | "betterdiscord") {
        return None;
    }
    value.get("plugin")?.as_str()?;
    let user_id = parse_snowflake(value.get("userId")?)?;
    let token = match value.get("token")? {
        Value::Null => None,
        Value::String(token) => Some(token.clone()),
        _ => return None,
    };
    Some(Hello {
        host: host.to_owned(),
        user_id,
        token,
    })
}

fn parse_dm(value: &Value) -> Option<DmInfo> {
    let channel_id = parse_snowflake(value.get("channelId")?)?;
    let peer = value.get("peer")?;
    let me = value.get("me")?;
    Some(DmInfo {
        channel_id,
        peer: UserInfo {
            id: parse_snowflake(peer.get("id")?)?,
            username: peer.get("username")?.as_str()?.to_owned(),
            global_name: peer
                .get("globalName")
                .and_then(Value::as_str)
                .map(str::to_owned),
            avatar_url: peer
                .get("avatarUrl")
                .and_then(Value::as_str)
                .map(str::to_owned),
        },
        me: UserInfo {
            id: parse_snowflake(me.get("id")?)?,
            username: me.get("username")?.as_str()?.to_owned(),
            global_name: me
                .get("globalName")
                .and_then(Value::as_str)
                .map(str::to_owned),
            avatar_url: me
                .get("avatarUrl")
                .and_then(Value::as_str)
                .map(str::to_owned),
        },
    })
}

fn parse_messages(value: &Value) -> Option<(ChannelId, Vec<WireMessage>, Option<MessageId>, bool)> {
    let channel = parse_snowflake(value.get("channelId")?)?;
    let messages = value.get("messages")?.as_array()?;
    let parsed = messages
        .iter()
        .map(parse_message)
        .collect::<Option<Vec<_>>>()?;
    let before = match value.get("before")? {
        Value::Null => None,
        value => Some(parse_snowflake(value)?),
    };
    let exhausted = value.get("exhausted")?.as_bool()?;
    Some((channel, parsed, before, exhausted))
}

fn parse_message(value: &Value) -> Option<WireMessage> {
    let edited_at = match value.get("editedAt")? {
        Value::Null => None,
        Value::String(timestamp) => Some(
            time::OffsetDateTime::parse(timestamp, &time::format_description::well_known::Rfc3339)
                .ok()?
                .unix_timestamp(),
        ),
        _ => return None,
    };
    let attachments = value
        .get("attachments")?
        .as_array()?
        .iter()
        .map(|attachment| {
            Some(AttachmentInfo {
                id: attachment.get("id")?.as_str()?.to_owned(),
                filename: attachment.get("filename")?.as_str()?.to_owned(),
                size: attachment.get("size")?.as_u64()?,
                url: attachment.get("url")?.as_str()?.to_owned(),
            })
        })
        .collect::<Option<Vec<_>>>()?;
    Some(WireMessage {
        id: parse_snowflake(value.get("id")?)?,
        author_id: parse_snowflake(value.get("authorId")?)?,
        content: value.get("content")?.as_str()?.to_owned(),
        edited_at,
        attachments,
    })
}

fn parse_deleted(value: &Value) -> Option<(ChannelId, Vec<MessageId>)> {
    let channel = parse_snowflake(value.get("channelId")?)?;
    let ids = value
        .get("ids")?
        .as_array()?
        .iter()
        .map(parse_snowflake)
        .collect::<Option<Vec<_>>>()?;
    Some((channel, ids))
}

fn parse_channel(value: &Value) -> Option<ChannelId> {
    parse_snowflake(value.get("channelId")?)
}

fn parse_sent(value: &Value) -> Option<(String, MessageId)> {
    Some((
        value.get("nonce")?.as_str()?.to_owned(),
        parse_snowflake(value.get("messageId")?)?,
    ))
}

fn parse_send_failed(value: &Value) -> Option<(String, String)> {
    Some((
        value.get("nonce")?.as_str()?.to_owned(),
        value.get("error")?.as_str()?.to_owned(),
    ))
}

fn parse_snowflake(value: &Value) -> Option<u64> {
    value.as_str()?.parse().ok()
}

fn validate_frame(frame: &CompanionFrame) -> Result<(), BridgeError> {
    let content = match frame {
        CompanionFrame::Send { content, .. } | CompanionFrame::Edit { content, .. } => content,
        CompanionFrame::Delete { .. }
        | CompanionFrame::NeedHistory { .. }
        | CompanionFrame::Status { .. } => return Ok(()),
    };
    match protocol::kind(content) {
        Kind::Handshake(_) | Kind::Encrypted(_) => Ok(()),
        Kind::Plain => Err(BridgeError::NotPrivate),
    }
}

fn clone_frame(frame: &CompanionFrame) -> CompanionFrame {
    match frame {
        CompanionFrame::Send {
            nonce,
            channel_id,
            content,
        } => CompanionFrame::Send {
            nonce: nonce.clone(),
            channel_id: *channel_id,
            content: content.clone(),
        },
        CompanionFrame::Edit {
            nonce,
            channel_id,
            message_id,
            content,
        } => CompanionFrame::Edit {
            nonce: nonce.clone(),
            channel_id: *channel_id,
            message_id: *message_id,
            content: content.clone(),
        },
        CompanionFrame::Delete {
            nonce,
            channel_id,
            message_id,
        } => CompanionFrame::Delete {
            nonce: nonce.clone(),
            channel_id: *channel_id,
            message_id: *message_id,
        },
        CompanionFrame::NeedHistory { channel_id, before } => CompanionFrame::NeedHistory {
            channel_id: *channel_id,
            before: *before,
        },
        CompanionFrame::Status {
            channel_id,
            state,
            verified,
            new_key,
            peer_class,
        } => CompanionFrame::Status {
            channel_id: *channel_id,
            state: state.clone(),
            verified: *verified,
            new_key: *new_key,
            peer_class: peer_class.clone(),
        },
    }
}

fn frame_value(frame: &CompanionFrame) -> Value {
    match frame {
        CompanionFrame::Send {
            nonce,
            channel_id,
            content,
        } => json!({"t":"send","nonce":nonce,"channelId":channel_id.to_string(),"content":content}),
        CompanionFrame::Edit {
            nonce,
            channel_id,
            message_id,
            content,
        } => {
            json!({"t":"edit","nonce":nonce,"channelId":channel_id.to_string(),"messageId":message_id.to_string(),"content":content})
        }
        CompanionFrame::Delete {
            nonce,
            channel_id,
            message_id,
        } => {
            json!({"t":"delete","nonce":nonce,"channelId":channel_id.to_string(),"messageId":message_id.to_string()})
        }
        CompanionFrame::NeedHistory { channel_id, before } => {
            json!({"t":"needHistory","channelId":channel_id.to_string(),"before":before.map(|id| id.to_string())})
        }
        CompanionFrame::Status {
            channel_id,
            state,
            verified,
            new_key,
            peer_class,
        } => {
            json!({"t":"status","channelId":channel_id.to_string(),"state":state,"verified":verified,"newKey":new_key,"peerClass":peer_class})
        }
    }
}

async fn send_json(socket: &mut WebSocketStream<TcpStream>, value: Value) -> Result<(), ()> {
    socket
        .send(Message::Text(value.to_string().into()))
        .await
        .map_err(|_| ())
}

async fn close_socket(socket: &mut WebSocketStream<TcpStream>, code: CloseCode, reason: &str) {
    let frame = CloseFrame {
        code,
        reason: reason.to_owned().into(),
    };
    let _ = socket.send(Message::Close(Some(frame))).await;
}

fn decode_token(token: &str) -> Option<Vec<u8>> {
    let token = URL_SAFE_NO_PAD.decode(token).ok()?;
    (token.len() == 32).then_some(token)
}

fn pairing_code() -> String {
    let mut random = [0u8; 4];
    getrandom::fill(&mut random).expect("OS random number generator available for pairing");
    format!("{:06}", u32::from_be_bytes(random) % 1_000_000)
}

fn update_connection(
    handle: &BridgeHandle,
    conn: ConnectionId,
    update: impl FnOnce(&mut Connection),
) {
    if let Some(connection) = lock_connections(&handle.connections).get_mut(&conn) {
        update(connection);
    }
}

fn lock_connections(
    connections: &Mutex<HashMap<ConnectionId, Connection>>,
) -> std::sync::MutexGuard<'_, HashMap<ConnectionId, Connection>> {
    connections
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct ConnectionPermit(Arc<AtomicUsize>);

impl Drop for ConnectionPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests;
