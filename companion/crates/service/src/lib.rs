#![forbid(unsafe_code)]
//! The headless core of the Duhcord Private Companion.
//!
//! It owns the bridge, the store and one [`Engine`] per Discord account, routes every plugin frame
//! through the engine, carries the engine's actions back to the plugin, saves the trust directory
//! whenever it changes, and offers a small API for the UI (the Tauri shell or a test).
//!
//! Plaintext only ever leaves this crate through that UI API, inside the companion's own process.
//! Everything sent to the bridge is checked by the bridge to be a handshake or an encrypted frame.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard, PoisonError},
    time::Duration,
};

use duhcord_companion_bridge::{
    Bridge, BridgeConfig, BridgeError, BridgeEvent, BridgeHandle, CompanionFrame, ConnectionId,
};
use duhcord_companion_engine::{
    AcceptError, Action, ChannelId, DmInfo, Engine, EngineError, MessageId, PeerClass, Status,
    Trust, UserId, UserInfo,
};
use duhcord_companion_store::{PairingRecord, Store, StoreError};
use duhcord_private_protocol::{self as protocol, FileKind, Host, Kind, PublicKey};
use serde::Serialize;
use thiserror::Error;
use tokio::sync::mpsc;

/// Largest sealed attachment the companion downloads (50 MiB plus the Poly1305 tag).
const MAX_SEALED_DOWNLOAD: u64 = protocol::MAX_FILE_LENGTH as u64 + 16;
const ALLOWED_MEDIA_HOSTS: [&str; 2] = ["cdn.discordapp.com", "media.discordapp.net"];
const DISCORD_EPOCH_MS: u64 = 1_420_070_400_000;

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("no Discord account {0} is connected to the companion")]
    NoAccount(UserId),
    #[error("the key store for this account is locked: {0}")]
    AccountLocked(String),
    #[error("the companion is locked")]
    SessionLocked,
    #[error("this direct message isn't known to the companion yet")]
    NoChat,
    #[error("Discord isn't connected to the companion right now")]
    NotConnected,
    #[error("that key isn't valid")]
    BadKey,
    #[error("the safety numbers don't match")]
    Mismatch,
    #[error("couldn't open the image: {0}")]
    Image(String),
    #[error(transparent)]
    Engine(#[from] EngineError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Bridge(#[from] BridgeError),
}

/// Something the UI should react to. None of these carry message text.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum UiEvent {
    #[serde(rename_all = "camelCase")]
    PairingRequested(PairingRequest),
    #[serde(rename_all = "camelCase")]
    PairingResolved {
        conn: ConnectionId,
    },
    AccountsChanged,
    #[serde(rename_all = "camelCase")]
    ChatChanged {
        user_id: String,
        channel_id: String,
    },
    #[serde(rename_all = "camelCase")]
    OpenChat {
        user_id: String,
        channel_id: String,
    },
    #[serde(rename_all = "camelCase")]
    OwnDevicesChanged {
        user_id: String,
    },
    #[serde(rename_all = "camelCase")]
    SendFailed {
        user_id: String,
        channel_id: String,
        error: String,
    },
    #[serde(rename_all = "camelCase")]
    Error {
        message: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingRequest {
    pub conn: ConnectionId,
    pub host: String,
    pub user_id: String,
    pub code: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountSummary {
    pub user_id: String,
    pub username: Option<String>,
    pub key_code: Option<String>,
    pub locked: Option<String>,
    pub hosts: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonDto {
    pub id: String,
    pub username: String,
    pub global_name: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StatusDto {
    pub state: &'static str,
    pub verified: bool,
    pub new_key: bool,
    pub peer_class: Option<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatSummary {
    pub channel_id: String,
    pub peer: PersonDto,
    pub status: StatusDto,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyDto {
    pub key: String,
    pub key_code: String,
    pub class: &'static str,
    pub trust: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageDto {
    pub id: String,
    pub from_me: bool,
    pub text: String,
    pub warnings: Vec<String>,
    pub trusted: bool,
    pub images: Vec<String>,
    pub unsupported_video: bool,
    pub timestamp_ms: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatDto {
    pub channel_id: String,
    pub peer: PersonDto,
    pub me: PersonDto,
    pub status: StatusDto,
    pub private: bool,
    pub messages: Vec<MessageDto>,
    pub accepted_keys: Vec<KeyDto>,
    pub pending_keys: Vec<KeyDto>,
    pub safety_number: Option<String>,
    pub my_key_code: String,
    /// Our side of the safety number: this device and our approved devices (spec §8).
    pub our_keys: Vec<KeyDto>,
    /// Their side: the keys of theirs that count.
    pub their_keys: Vec<KeyDto>,
    pub can_send: bool,
    pub has_our_key: bool,
    pub companion_excluded: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnDeviceDto {
    pub key: String,
    pub key_code: String,
    pub trust: &'static str,
    pub class: &'static str,
    pub added: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingDto {
    pub token_hash: String,
    pub host: String,
    pub user_id: String,
    pub created_at: u64,
}

/// A decrypted image, held only in memory.
pub struct ImageData {
    pub mime: &'static str,
    pub bytes: zeroize::Zeroizing<Vec<u8>>,
}

enum Account {
    Open(Box<Engine>),
    Locked(String),
}

struct ReadyConnection {
    user_id: UserId,
    host: String,
    order: u64,
}

struct Outgoing {
    user_id: UserId,
    channel: ChannelId,
    handshake: bool,
}

#[derive(Default)]
struct Inner {
    accounts: HashMap<UserId, Account>,
    usernames: HashMap<UserId, String>,
    connections: HashMap<ConnectionId, ReadyConnection>,
    pairings: HashMap<ConnectionId, PairingRequest>,
    outgoing: HashMap<String, Outgoing>,
    next_order: u64,
    session_locked: bool,
}

#[derive(Clone)]
pub struct Service {
    inner: Arc<Mutex<Inner>>,
    bridge: BridgeHandle,
    store: Arc<Store>,
    ui: mpsc::UnboundedSender<UiEvent>,
    http: reqwest::Client,
    config_dir: PathBuf,
}

impl Service {
    /// Opens the store in `config_dir`, starts the bridge and the event loop.
    pub async fn start(
        config_dir: impl AsRef<Path>,
        config: BridgeConfig,
    ) -> Result<(Self, mpsc::UnboundedReceiver<UiEvent>), ServiceError> {
        let config_dir = config_dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&config_dir).map_err(StoreError::from)?;
        let store = Arc::new(Store::open(&config_dir)?);
        let (bridge, mut events) =
            Bridge::start_with_store(&config_dir, Arc::clone(&store), config).await?;
        let (ui, ui_rx) = mpsc::unbounded_channel();
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() >= 3 || !allowed_media_url(attempt.url()) {
                    attempt.stop()
                } else {
                    attempt.follow()
                }
            }))
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(120))
            .https_only(true)
            .build()
            .map_err(|error| ServiceError::Image(error.to_string()))?;
        let service = Self {
            inner: Arc::new(Mutex::new(Inner::default())),
            bridge,
            store,
            ui,
            http,
            config_dir,
        };
        let worker = service.clone();
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                worker.handle_bridge_event(event);
            }
        });
        Ok((service, ui_rx))
    }

    pub fn bridge_port(&self) -> u16 {
        self.bridge.local_addr().port()
    }

    pub fn config_dir(&self) -> &Path {
        &self.config_dir
    }

    pub async fn shutdown(&self) {
        self.bridge.shutdown().await;
    }

    // ---- bridge events -------------------------------------------------------------------------

    fn handle_bridge_event(&self, event: BridgeEvent) {
        match event {
            BridgeEvent::PairingRequested {
                conn,
                host,
                user_id,
                code,
            } => {
                let request = PairingRequest {
                    conn,
                    host,
                    user_id: user_id.to_string(),
                    code,
                };
                self.lock().pairings.insert(conn, request.clone());
                self.emit(UiEvent::PairingRequested(request));
            }
            BridgeEvent::Ready {
                conn,
                user_id,
                host,
            } => self.on_ready(conn, user_id, host),
            BridgeEvent::Dm { conn, info } => self.on_dm(conn, info),
            BridgeEvent::Messages {
                conn,
                channel,
                messages,
                before,
                exhausted,
            } => self.with_connection_engine(conn, channel, |engine| {
                engine.on_messages(channel, messages, before, exhausted)
            }),
            BridgeEvent::Deleted { conn, channel, ids } => {
                self.with_connection_engine(conn, channel, |engine| {
                    engine.on_deleted(channel, &ids)
                })
            }
            BridgeEvent::Open { conn, channel } => {
                let user = self.lock().connections.get(&conn).map(|c| c.user_id);
                if let Some(user_id) = user {
                    self.emit(UiEvent::OpenChat {
                        user_id: user_id.to_string(),
                        channel_id: channel.to_string(),
                    });
                }
            }
            BridgeEvent::Sent { nonce, .. } => {
                self.lock().outgoing.remove(&nonce);
            }
            BridgeEvent::SendFailed { nonce, error, .. } => {
                let outgoing = self.lock().outgoing.remove(&nonce);
                if let Some(outgoing) = outgoing {
                    self.send_failed(outgoing, error);
                }
            }
            BridgeEvent::Disconnected { conn, .. } => {
                let (had_pairing, had_ready) = {
                    let mut inner = self.lock();
                    (
                        inner.pairings.remove(&conn).is_some(),
                        inner.connections.remove(&conn).is_some(),
                    )
                };
                if had_pairing {
                    self.emit(UiEvent::PairingResolved { conn });
                }
                if had_ready {
                    self.emit(UiEvent::AccountsChanged);
                }
            }
        }
    }

    fn on_ready(&self, conn: ConnectionId, user_id: UserId, host: String) {
        let had_pairing = {
            let mut inner = self.lock();
            let had_pairing = inner.pairings.remove(&conn).is_some();
            inner.next_order += 1;
            let order = inner.next_order;
            inner.connections.insert(
                conn,
                ReadyConnection {
                    user_id,
                    host: host.clone(),
                    order,
                },
            );
            // A locked key store gets another try each time the plugin connects.
            if !matches!(inner.accounts.get(&user_id), Some(Account::Open(_))) {
                let account = self.open_account(user_id);
                inner.accounts.insert(user_id, account);
            }
            let locked = inner.session_locked;
            if let Some(Account::Open(engine)) = inner.accounts.get_mut(&user_id) {
                engine.set_host(host_from_name(&host));
                engine.set_locked(locked);
            }
            had_pairing
        };
        if had_pairing {
            self.emit(UiEvent::PairingResolved { conn });
        }
        self.emit(UiEvent::AccountsChanged);
        // A reconnecting plugin gets the badges for every DM we already know.
        let channels: Vec<ChannelId> = {
            let inner = self.lock();
            match inner.accounts.get(&user_id) {
                Some(Account::Open(engine)) => engine.dms().map(|dm| dm.channel_id).collect(),
                _ => Vec::new(),
            }
        };
        for channel in channels {
            self.push_status(user_id, channel);
        }
    }

    fn open_account(&self, user_id: UserId) -> Account {
        match self.store.load_account(user_id) {
            Ok(Some((keys, directory))) => Account::Open(Box::new(Engine::new(keys, directory))),
            Ok(None) => match self.store.create_account(user_id) {
                Ok(keys) => {
                    let engine = Engine::new(keys, Default::default());
                    if let Err(error) = self
                        .store
                        .save_directory(engine.account(), engine.directory())
                    {
                        self.emit(UiEvent::Error {
                            message: format!("Couldn't save the new account: {error}"),
                        });
                    }
                    Account::Open(Box::new(engine))
                }
                Err(error) => Account::Locked(error.to_string()),
            },
            Err(error) => Account::Locked(error.to_string()),
        }
    }

    fn on_dm(&self, conn: ConnectionId, info: DmInfo) {
        let channel = info.channel_id;
        let user_id = {
            let mut inner = self.lock();
            let Some(user_id) = inner.connections.get(&conn).map(|c| c.user_id) else {
                return;
            };
            if info.me.id != user_id {
                return;
            }
            inner.usernames.insert(user_id, info.me.username.clone());
            user_id
        };
        self.run(user_id, Some(conn), |engine| engine.on_dm(info));
        // Always answer a dm with its badge, even when nothing changed (e.g. after a reconnect).
        self.push_status(user_id, channel);
    }

    fn with_connection_engine(
        &self,
        conn: ConnectionId,
        channel: ChannelId,
        operation: impl FnOnce(&mut Engine) -> Vec<Action>,
    ) {
        let user = self.lock().connections.get(&conn).map(|c| c.user_id);
        if let Some(user_id) = user {
            self.run(user_id, Some(conn), operation);
            self.emit(UiEvent::ChatChanged {
                user_id: user_id.to_string(),
                channel_id: channel.to_string(),
            });
        }
    }

    /// Runs an engine operation, saves the directory if it changed and carries out the actions.
    fn run<T>(
        &self,
        user_id: UserId,
        conn: Option<ConnectionId>,
        operation: impl FnOnce(&mut Engine) -> T,
    ) -> Option<T>
    where
        T: IntoActions,
    {
        let (result, actions) = {
            let mut inner = self.lock();
            let Some(Account::Open(engine)) = inner.accounts.get_mut(&user_id) else {
                return None;
            };
            let mut result = operation(engine);
            let actions = result.take_actions();
            self.persist(engine);
            (result, actions)
        };
        self.carry_out(user_id, conn, actions);
        Some(result)
    }

    fn persist(&self, engine: &mut Engine) {
        if !engine.directory_dirty() {
            return;
        }
        match self
            .store
            .save_directory(engine.account(), engine.directory())
        {
            Ok(()) => engine.mark_directory_clean(),
            Err(error) => self.emit(UiEvent::Error {
                message: format!("Couldn't save the trust directory: {error}"),
            }),
        }
    }

    fn carry_out(&self, user_id: UserId, conn: Option<ConnectionId>, actions: Vec<Action>) {
        let mut status_channels = Vec::new();
        for action in actions {
            match action {
                Action::Send { channel, content } => {
                    let handshake = matches!(protocol::kind(&content), Kind::Handshake(_));
                    let Some(target) = self.target_connection(user_id, conn) else {
                        if handshake {
                            self.run(user_id, None, |engine| {
                                engine.handshake_send_failed(channel)
                            });
                        }
                        self.emit(UiEvent::SendFailed {
                            user_id: user_id.to_string(),
                            channel_id: channel.to_string(),
                            error: ServiceError::NotConnected.to_string(),
                        });
                        continue;
                    };
                    let nonce = random_nonce();
                    self.lock().outgoing.insert(
                        nonce.clone(),
                        Outgoing {
                            user_id,
                            channel,
                            handshake,
                        },
                    );
                    let sent = self.bridge.send(
                        target,
                        CompanionFrame::Send {
                            nonce: nonce.clone(),
                            channel_id: channel,
                            content,
                        },
                    );
                    if let Err(error) = sent {
                        if let Some(outgoing) = self.lock().outgoing.remove(&nonce) {
                            self.send_failed(outgoing, error.to_string());
                        }
                    }
                }
                Action::NeedHistory { channel, before } => {
                    if let Some(target) = self.target_connection(user_id, conn) {
                        let _ = self.bridge.send(
                            target,
                            CompanionFrame::NeedHistory {
                                channel_id: channel,
                                before: Some(before),
                            },
                        );
                    }
                }
                Action::StatusChanged { channel } => {
                    if !status_channels.contains(&channel) {
                        status_channels.push(channel);
                    }
                }
            }
        }
        for changed in status_channels {
            self.push_status(user_id, changed);
            self.emit(UiEvent::ChatChanged {
                user_id: user_id.to_string(),
                channel_id: changed.to_string(),
            });
        }
    }

    fn send_failed(&self, outgoing: Outgoing, error: String) {
        if outgoing.handshake {
            let channel = outgoing.channel;
            self.run(outgoing.user_id, None, |engine| {
                engine.handshake_send_failed(channel)
            });
        }
        self.emit(UiEvent::SendFailed {
            user_id: outgoing.user_id.to_string(),
            channel_id: outgoing.channel.to_string(),
            error,
        });
    }

    /// The connection that posts for this account: the one that asked, else the newest.
    fn target_connection(
        &self,
        user_id: UserId,
        preferred: Option<ConnectionId>,
    ) -> Option<ConnectionId> {
        let inner = self.lock();
        if let Some(conn) = preferred {
            if inner
                .connections
                .get(&conn)
                .is_some_and(|c| c.user_id == user_id)
            {
                return Some(conn);
            }
        }
        inner
            .connections
            .iter()
            .filter(|(_, c)| c.user_id == user_id)
            .max_by_key(|(_, c)| c.order)
            .map(|(conn, _)| *conn)
    }

    fn push_status(&self, user_id: UserId, channel: ChannelId) {
        let status = {
            let inner = self.lock();
            match inner.accounts.get(&user_id) {
                Some(Account::Open(engine)) => status_dto(engine.status(channel)),
                Some(Account::Locked(_)) => StatusDto {
                    state: "locked",
                    verified: false,
                    new_key: false,
                    peer_class: None,
                },
                None => return,
            }
        };
        let _ = self.bridge.send_user(
            user_id,
            CompanionFrame::Status {
                channel_id: channel,
                state: status.state.to_owned(),
                verified: status.verified,
                new_key: status.new_key,
                peer_class: status.peer_class.map(str::to_owned),
            },
        );
    }

    // ---- UI API --------------------------------------------------------------------------------

    pub fn accounts(&self) -> Vec<AccountSummary> {
        let inner = self.lock();
        let mut accounts: Vec<_> = inner
            .accounts
            .iter()
            .map(|(user_id, account)| {
                let mut hosts: Vec<String> = inner
                    .connections
                    .values()
                    .filter(|c| c.user_id == *user_id)
                    .map(|c| c.host.clone())
                    .collect();
                hosts.sort();
                hosts.dedup();
                let (key_code, locked) = match account {
                    Account::Open(engine) => (Some(protocol::key_code(&engine.public_key())), None),
                    Account::Locked(reason) => (None, Some(reason.clone())),
                };
                AccountSummary {
                    user_id: user_id.to_string(),
                    username: inner.usernames.get(user_id).cloned(),
                    key_code,
                    locked,
                    hosts,
                }
            })
            .collect();
        accounts.sort_by(|a, b| a.user_id.cmp(&b.user_id));
        accounts
    }

    pub fn chats(&self, user_id: UserId) -> Result<Vec<ChatSummary>, ServiceError> {
        self.read(user_id, |engine| {
            let mut chats: Vec<_> = engine
                .dms()
                .map(|dm| ChatSummary {
                    channel_id: dm.channel_id.to_string(),
                    peer: person(&dm.peer),
                    status: status_dto(engine.status(dm.channel_id)),
                })
                .collect();
            chats.sort_by(|a, b| a.peer.username.cmp(&b.peer.username));
            Ok(chats)
        })
    }

    pub fn chat(&self, user_id: UserId, channel: ChannelId) -> Result<ChatDto, ServiceError> {
        self.read(user_id, |engine| {
            let dm = engine.dm(channel).ok_or(ServiceError::NoChat)?;
            let keys = engine
                .directory()
                .people
                .get(&dm.peer.id)
                .cloned()
                .unwrap_or_default();
            let key_dto = |key: &duhcord_companion_engine::PeerKey| KeyDto {
                key: hex::encode(key.key),
                key_code: protocol::key_code(&key.key),
                class: class_name(key.class),
                trust: trust_name(key.trust),
            };
            let messages = engine
                .view(channel)
                .iter()
                .map(|view| MessageDto {
                    id: view.id.to_string(),
                    from_me: view.from_me,
                    text: view.text.clone(),
                    warnings: view.warnings.iter().map(|warning| warning.text()).collect(),
                    trusted: view.trusted,
                    images: if view.trusted {
                        view.images
                            .iter()
                            .map(|image| image.attachment_id.clone())
                            .collect()
                    } else {
                        Vec::new()
                    },
                    unsupported_video: view.unsupported_video,
                    timestamp_ms: (view.id >> 22) + DISCORD_EPOCH_MS,
                })
                .collect();
            let status = engine.status(channel);
            let peer_id = dm.peer.id;
            let class_of = |class: duhcord_private_protocol::ClientClass| match class {
                duhcord_private_protocol::ClientClass::Duhcord => "duhcord",
                duhcord_private_protocol::ClientClass::Companion => "companion",
            };
            let our_keys = engine
                .our_side()
                .into_iter()
                .map(|(key, class)| KeyDto {
                    key: hex::encode(key),
                    key_code: protocol::key_code(&key),
                    class: class_of(class),
                    trust: "accepted",
                })
                .collect();
            let their_keys = keys
                .iter()
                .filter(|key| engine.counts(peer_id, key))
                .map(key_dto)
                .collect();
            Ok(ChatDto {
                our_keys,
                their_keys,
                can_send: status.can_send(),
                has_our_key: engine.has_our_key(channel),
                companion_excluded: engine.companion_excluded(channel),
                channel_id: channel.to_string(),
                peer: person(&dm.peer),
                me: person(&dm.me),
                status: status_dto(status),
                private: engine.directory().private_channels.contains(&channel),
                messages,
                accepted_keys: keys
                    .iter()
                    .filter(|key| key.trust == Trust::Accepted)
                    .map(key_dto)
                    .collect(),
                pending_keys: keys
                    .iter()
                    .filter(|key| key.trust == Trust::Pending)
                    .map(key_dto)
                    .collect(),
                safety_number: engine.safety_number(channel, &[]),
                my_key_code: protocol::key_code(&engine.public_key()),
            })
        })
    }

    /// Seals text typed in the companion and asks the plugin to post it.
    pub fn send_text(
        &self,
        user_id: UserId,
        channel: ChannelId,
        text: &str,
    ) -> Result<(), ServiceError> {
        let text = text.trim_end();
        if text.is_empty() {
            return Ok(());
        }
        if self.target_connection(user_id, None).is_none() {
            return Err(ServiceError::NotConnected);
        }
        self.write(user_id, channel, |engine| {
            engine
                .seal_text(channel, text)
                .map(|action| vec![action])
                .map_err(ServiceError::from)
        })
    }

    /// Turns Private on (sending our handshake when needed) or off for a DM. Turning it on also
    /// answers a pending request from the peer.
    pub fn set_private(
        &self,
        user_id: UserId,
        channel: ChannelId,
        enabled: bool,
    ) -> Result<(), ServiceError> {
        self.write(user_id, channel, |engine| {
            if engine.dm(channel).is_none() {
                return Err(ServiceError::NoChat);
            }
            Ok(engine.set_private(channel, enabled))
        })
    }

    /// "Re-send my key" (spec §3 rule 4).
    pub fn resend_key(&self, user_id: UserId, channel: ChannelId) -> Result<(), ServiceError> {
        self.write(user_id, channel, |engine| {
            if engine.dm(channel).is_none() {
                return Err(ServiceError::NoChat);
            }
            Ok(engine.resend_key(channel))
        })
    }

    /// Keeps this person's Companion keys out of the chat (spec §6), or lets them back in.
    pub fn set_companion_excluded(
        &self,
        user_id: UserId,
        channel: ChannelId,
        excluded: bool,
    ) -> Result<(), ServiceError> {
        self.write(user_id, channel, |engine| {
            if engine.dm(channel).is_none() {
                return Err(ServiceError::NoChat);
            }
            Ok(engine.set_companion_excluded(channel, excluded))
        })
    }

    /// Safety number as it would be with `accepting` added to their side (for the accept sheet).
    pub fn safety_number(
        &self,
        user_id: UserId,
        channel: ChannelId,
        accepting: &[String],
    ) -> Result<Option<String>, ServiceError> {
        let keys = parse_keys(accepting)?;
        self.read(user_id, |engine| Ok(engine.safety_number(channel, &keys)))
    }

    /// Accepts pending keys. With `compared`, the user compared that safety number with the peer,
    /// so it must match and the chat becomes verified.
    pub fn accept_keys(
        &self,
        user_id: UserId,
        channel: ChannelId,
        keys: &[String],
        compared: Option<&str>,
    ) -> Result<(), ServiceError> {
        let keys = parse_keys(keys)?;
        self.write(user_id, channel, |engine| {
            engine
                .accept_keys(channel, &keys, compared)
                .map_err(|error| match error {
                    AcceptError::Mismatch => ServiceError::Mismatch,
                    AcceptError::NoChat => ServiceError::NoChat,
                    AcceptError::NothingPending => ServiceError::BadKey,
                })
        })
    }

    pub fn reject_keys(
        &self,
        user_id: UserId,
        channel: ChannelId,
        keys: &[String],
    ) -> Result<(), ServiceError> {
        let keys = parse_keys(keys)?;
        self.write(user_id, channel, |engine| {
            Ok(engine.reject_keys(channel, &keys))
        })
    }

    /// Marks the current safety number as compared with the peer.
    pub fn mark_verified(&self, user_id: UserId, channel: ChannelId) -> Result<(), ServiceError> {
        self.write(user_id, channel, |engine| {
            if engine.mark_verified(channel) {
                Ok(vec![Action::StatusChanged { channel }])
            } else {
                Err(ServiceError::NoChat)
            }
        })
    }

    pub fn own_devices(&self, user_id: UserId) -> Result<Vec<OwnDeviceDto>, ServiceError> {
        self.read(user_id, |engine| {
            Ok(engine
                .devices()
                .iter()
                .map(|device| OwnDeviceDto {
                    key: hex::encode(device.key),
                    key_code: protocol::key_code(&device.key),
                    trust: trust_name(device.trust),
                    class: class_name(device.class),
                    added: device.added,
                })
                .collect())
        })
    }

    pub fn set_own_device(
        &self,
        user_id: UserId,
        key: &str,
        accept: bool,
    ) -> Result<(), ServiceError> {
        let key = parse_key(key)?;
        let channels = {
            let mut inner = self.lock();
            let Some(Account::Open(engine)) = inner.accounts.get_mut(&user_id) else {
                return Err(ServiceError::NoAccount(user_id));
            };
            let changed = engine.set_device(
                key,
                if accept {
                    Trust::Accepted
                } else {
                    Trust::Rejected
                },
            );
            if !changed {
                return Err(ServiceError::BadKey);
            }
            self.persist(engine);
            engine.dms().map(|dm| dm.channel_id).collect::<Vec<_>>()
        };
        for channel in channels {
            self.push_status(user_id, channel);
        }
        self.emit(UiEvent::OwnDevicesChanged {
            user_id: user_id.to_string(),
        });
        Ok(())
    }

    pub fn pending_pairings(&self) -> Vec<PairingRequest> {
        let mut pairings: Vec<_> = self.lock().pairings.values().cloned().collect();
        pairings.sort_by_key(|pairing| pairing.conn);
        pairings
    }

    pub fn approve_pairing(&self, conn: ConnectionId) -> Result<(), ServiceError> {
        Ok(self.bridge.approve_pairing(conn)?)
    }

    pub fn deny_pairing(&self, conn: ConnectionId) -> Result<(), ServiceError> {
        self.lock().pairings.remove(&conn);
        self.bridge.deny_pairing(conn)?;
        self.emit(UiEvent::PairingResolved { conn });
        Ok(())
    }

    pub fn pairings(&self) -> Result<Vec<PairingDto>, ServiceError> {
        Ok(self
            .store
            .pairings()?
            .into_iter()
            .map(
                |PairingRecord {
                     token_hash,
                     host,
                     user_id,
                     created_at,
                 }| PairingDto {
                    token_hash,
                    host,
                    user_id: user_id.to_string(),
                    created_at,
                },
            )
            .collect())
    }

    pub fn revoke_pairing(&self, token_hash: &str) -> Result<bool, ServiceError> {
        let hash: [u8; 32] = hex::decode(token_hash)
            .ok()
            .and_then(|bytes| bytes.try_into().ok())
            .ok_or(ServiceError::BadKey)?;
        let revoked = self.bridge.revoke(hash)?;
        self.emit(UiEvent::AccountsChanged);
        Ok(revoked)
    }

    pub fn is_locked(&self) -> bool {
        self.lock().session_locked
    }

    /// Locks every account: decrypted messages are dropped from memory and nothing can be sent
    /// until [`Service::unlock`].
    pub fn lock_session(&self) {
        let targets = {
            let mut inner = self.lock();
            inner.session_locked = true;
            let mut targets = Vec::new();
            for (user_id, account) in inner.accounts.iter_mut() {
                if let Account::Open(engine) = account {
                    engine.set_locked(true);
                    engine.forget_messages();
                    targets.extend(engine.dms().map(|dm| (*user_id, dm.channel_id)));
                }
            }
            targets
        };
        for (user_id, channel) in targets {
            self.push_status(user_id, channel);
        }
        self.emit(UiEvent::AccountsChanged);
    }

    /// Unlocks and asks every plugin to send the private messages again.
    pub fn unlock_session(&self) {
        let targets = {
            let mut inner = self.lock();
            inner.session_locked = false;
            let mut targets = Vec::new();
            for (user_id, account) in inner.accounts.iter_mut() {
                if let Account::Open(engine) = account {
                    engine.set_locked(false);
                    targets.extend(engine.dms().map(|dm| (*user_id, dm.channel_id)));
                }
            }
            targets
        };
        for (user_id, channel) in targets {
            self.push_status(user_id, channel);
            if let Some(conn) = self.target_connection(user_id, None) {
                let _ = self.bridge.send(
                    conn,
                    CompanionFrame::NeedHistory {
                        channel_id: channel,
                        before: None,
                    },
                );
            }
        }
        self.emit(UiEvent::AccountsChanged);
    }

    /// Downloads and decrypts an image from a trusted private message, in memory only.
    pub async fn fetch_image(
        &self,
        user_id: UserId,
        channel: ChannelId,
        message: MessageId,
        attachment_id: &str,
    ) -> Result<ImageData, ServiceError> {
        let image = self.read(user_id, |engine| {
            engine
                .view(channel)
                .into_iter()
                .find(|view| view.id == message && view.trusted)
                .and_then(|view| {
                    view.images
                        .iter()
                        .find(|image| image.attachment_id == attachment_id)
                        .cloned()
                })
                .ok_or_else(|| ServiceError::Image("no such image".to_owned()))
        })?;
        let url = url::Url::parse(&image.url)
            .ok()
            .filter(allowed_media_url)
            .ok_or_else(|| ServiceError::Image("not a Discord media URL".to_owned()))?;
        let expected = u64::from(image.file.sealed_length);
        if expected > MAX_SEALED_DOWNLOAD {
            return Err(ServiceError::Image("too large".to_owned()));
        }
        let mut response = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|error| ServiceError::Image(error.to_string()))?;
        if !response.status().is_success() || !allowed_media_url(response.url()) {
            return Err(ServiceError::Image(format!(
                "download failed ({})",
                response.status()
            )));
        }
        if response
            .content_length()
            .is_some_and(|length| length != expected)
        {
            return Err(ServiceError::Image("unexpected size".to_owned()));
        }
        let mut sealed = Vec::with_capacity(expected as usize);
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| ServiceError::Image(error.to_string()))?
        {
            if sealed.len() as u64 + chunk.len() as u64 > expected {
                return Err(ServiceError::Image("unexpected size".to_owned()));
            }
            sealed.extend_from_slice(&chunk);
        }
        decrypt_image(&sealed, &image.file)
    }

    // ---- helpers -------------------------------------------------------------------------------

    fn read<T>(
        &self,
        user_id: UserId,
        operation: impl FnOnce(&Engine) -> Result<T, ServiceError>,
    ) -> Result<T, ServiceError> {
        let inner = self.lock();
        match inner.accounts.get(&user_id) {
            Some(Account::Open(engine)) => operation(engine),
            Some(Account::Locked(reason)) => Err(ServiceError::AccountLocked(reason.clone())),
            None => Err(ServiceError::NoAccount(user_id)),
        }
    }

    fn write(
        &self,
        user_id: UserId,
        channel: ChannelId,
        operation: impl FnOnce(&mut Engine) -> Result<Vec<Action>, ServiceError>,
    ) -> Result<(), ServiceError> {
        if self.is_locked() {
            return Err(ServiceError::SessionLocked);
        }
        {
            let inner = self.lock();
            match inner.accounts.get(&user_id) {
                Some(Account::Open(_)) => {}
                Some(Account::Locked(reason)) => {
                    return Err(ServiceError::AccountLocked(reason.clone()))
                }
                None => return Err(ServiceError::NoAccount(user_id)),
            }
        }
        let result = self
            .run(user_id, None, operation)
            .ok_or(ServiceError::NoAccount(user_id))?;
        result?;
        self.emit(UiEvent::ChatChanged {
            user_id: user_id.to_string(),
            channel_id: channel.to_string(),
        });
        Ok(())
    }

    fn emit(&self, event: UiEvent) {
        let _ = self.ui.send(event);
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Engine operations either return actions directly or wrap them in a `Result`.
trait IntoActions {
    fn take_actions(&mut self) -> Vec<Action>;
}

impl IntoActions for Vec<Action> {
    fn take_actions(&mut self) -> Vec<Action> {
        std::mem::take(self)
    }
}

impl IntoActions for () {
    fn take_actions(&mut self) -> Vec<Action> {
        Vec::new()
    }
}

impl IntoActions for Result<Vec<Action>, ServiceError> {
    fn take_actions(&mut self) -> Vec<Action> {
        match self {
            Ok(actions) => std::mem::take(actions),
            Err(_) => Vec::new(),
        }
    }
}

fn decrypt_image(sealed: &[u8], file: &protocol::PrivateFile) -> Result<ImageData, ServiceError> {
    let plain = zeroize::Zeroizing::new(
        protocol::open_file(sealed, file)
            .ok_or_else(|| ServiceError::Image("decryption failed".to_owned()))?,
    );
    let mime = match file.kind {
        FileKind::Jpeg if plain.starts_with(&[0xFF, 0xD8, 0xFF]) => "image/jpeg",
        FileKind::Png if plain.starts_with(b"\x89PNG\r\n\x1a\n") => "image/png",
        _ => return Err(ServiceError::Image("not a JPEG or PNG".to_owned())),
    };
    Ok(ImageData { mime, bytes: plain })
}

fn allowed_media_url(url: &url::Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url
            .host_str()
            .is_some_and(|host| ALLOWED_MEDIA_HOSTS.contains(&host))
}

fn random_nonce() -> String {
    let mut bytes = [0u8; 12];
    getrandom::fill(&mut bytes).expect("OS random number generator available");
    hex::encode(bytes)
}

fn parse_key(key: &str) -> Result<PublicKey, ServiceError> {
    hex::decode(key)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(ServiceError::BadKey)
}

fn parse_keys(keys: &[String]) -> Result<Vec<PublicKey>, ServiceError> {
    keys.iter().map(|key| parse_key(key)).collect()
}

fn host_from_name(host: &str) -> Host {
    match host {
        "vencord" => Host::VENCORD,
        "vesktop" => Host::VESKTOP,
        "replugged" => Host::REPLUGGED,
        "betterdiscord" => Host::BETTERDISCORD,
        "dorion" => Host::DORION,
        _ => Host::UNKNOWN,
    }
}

fn person(user: &UserInfo) -> PersonDto {
    PersonDto {
        id: user.id.to_string(),
        username: user.username.clone(),
        global_name: user.global_name.clone(),
        avatar_url: user.avatar_url.clone(),
    }
}

fn status_dto(status: Status) -> StatusDto {
    StatusDto {
        state: status.state.as_str(),
        verified: status.verified,
        new_key: status.new_key,
        peer_class: status.peer_class.map(class_name),
    }
}

fn class_name(class: PeerClass) -> &'static str {
    match class {
        PeerClass::Duhcord => "duhcord",
        PeerClass::Companion => "companion",
    }
}

fn trust_name(trust: Trust) -> &'static str {
    match trust {
        Trust::Accepted => "accepted",
        Trust::Pending => "pending",
        Trust::Rejected => "rejected",
    }
}

#[cfg(test)]
mod tests;
