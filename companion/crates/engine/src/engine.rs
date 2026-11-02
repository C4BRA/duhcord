//! The per-account private-messaging state machine, protocol v3 (spec/PROTOCOL.md §3, §6–§8).
//!
//! One `Engine` per Discord account. It reads a DM's messages (handshakes and encrypted messages), decides which keys
//! are trusted and what state the DM is in, and says what to send. It never touches the network: the caller carries
//! out the returned [`Action`]s. The same engine plays a Duhcord or a Companion device ([`EngineConfig`]), so the
//! shared scenarios (spec/SCENARIOS.md) can simulate both sides with it.

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    time::{SystemTime, UNIX_EPOCH},
};

use duhcord_private_protocol::{
    self as protocol, key_id, ClientClass, Features, Handshake, Host, Kind, PrivateFile,
    PrivateKey, PublicKey, SealError, MAX_ACCEPTED_KEY_IDS, MAX_RECIPIENTS,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;
use zeroize::Zeroize;

pub type UserId = u64;
pub type ChannelId = u64;
pub type MessageId = u64;
pub type KeyId = [u8; 4];

const MAX_PENDING_KEYS: usize = 4;
const MAX_ACCEPTED_DEVICES: usize = 3;
const REPLAY_TOLERANCE_SECONDS: i64 = 10 * 60;
const DISCORD_EPOCH_SECONDS: i64 = 1_420_070_400;

pub struct AccountKeys {
    user_id: UserId,
    private_key: PrivateKey,
    directory_key: zeroize::Zeroizing<[u8; 32]>,
}

impl AccountKeys {
    pub fn new(user_id: UserId, mut private_key: [u8; 32], mut directory_key: [u8; 32]) -> Self {
        let key = PrivateKey::from_bytes(private_key);
        private_key.zeroize();
        let protected_directory_key = zeroize::Zeroizing::new(directory_key);
        directory_key.zeroize();
        Self {
            user_id,
            private_key: key,
            directory_key: protected_directory_key,
        }
    }

    pub fn user_id(&self) -> UserId {
        self.user_id
    }

    pub fn public_key(&self) -> PublicKey {
        self.private_key.public_key()
    }

    pub fn private_key(&self) -> &PrivateKey {
        &self.private_key
    }

    pub fn private_key_bytes(&self) -> zeroize::Zeroizing<[u8; 32]> {
        self.private_key.to_bytes()
    }

    pub fn directory_key(&self) -> &[u8; 32] {
        &self.directory_key
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PeerClass {
    Duhcord,
    Companion,
}

impl From<ClientClass> for PeerClass {
    fn from(class: ClientClass) -> Self {
        match class {
            ClientClass::Duhcord => Self::Duhcord,
            ClientClass::Companion => Self::Companion,
        }
    }
}

impl From<PeerClass> for ClientClass {
    fn from(class: PeerClass) -> Self {
        match class {
            PeerClass::Duhcord => Self::Duhcord,
            PeerClass::Companion => Self::Companion,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Trust {
    Accepted,
    Pending,
    Rejected,
}

/// One key of the other person.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerKey {
    pub key: PublicKey,
    pub added: u64,
    pub trust: Trust,
    pub class: PeerClass,
    pub features: u16,
}

/// One of the user's own other installs (spec §7).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnDevice {
    pub key: PublicKey,
    pub added: u64,
    pub trust: Trust,
    pub class: PeerClass,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayRecord {
    pub message_id: MessageId,
}

/// The latest evidence of whether the other person has accepted our current key (spec §6 "Receipts"): the newest
/// handshake or trusted message of theirs that says so either way.
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    pub message_id: MessageId,
    pub has_our_key: bool,
}

/// Everything kept per account, encrypted at rest by the store.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Directory {
    pub people: HashMap<UserId, Vec<PeerKey>>,
    pub devices: Vec<OwnDevice>,
    pub consented: HashSet<UserId>,
    pub private_channels: HashSet<ChannelId>,
    pub verified: HashMap<UserId, [u8; 32]>,
    pub first_with_salt: HashMap<String, ReplayRecord>,
    /// People whose Companion keys the user excluded (spec §6 "Which keys count").
    pub companion_excluded: HashSet<UserId>,
    pub receipts: HashMap<UserId, Receipt>,
    /// DMs where our current key's handshake has been echoed back at least once (spec §3 rule 1).
    pub handshake_sent: HashSet<ChannelId>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct UserInfo {
    pub id: UserId,
    pub username: String,
    pub global_name: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct DmInfo {
    pub channel_id: ChannelId,
    pub peer: UserInfo,
    pub me: UserInfo,
}

#[derive(Clone, PartialEq, Eq)]
pub struct AttachmentInfo {
    pub id: String,
    pub filename: String,
    pub size: u64,
    pub url: String,
}

#[derive(Clone, PartialEq, Eq)]
pub struct WireMessage {
    pub id: MessageId,
    pub author_id: UserId,
    pub content: String,
    pub edited_at: Option<i64>,
    pub attachments: Vec<AttachmentInfo>,
}

/// A DM's private-messaging state (spec §6, the same in both clients and on the bridge).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Off,
    Request,
    Waiting,
    Unconfirmed,
    Ready,
    Outdated,
    Locked,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Request => "request",
            Self::Waiting => "waiting",
            Self::Unconfirmed => "unconfirmed",
            Self::Ready => "ready",
            Self::Outdated => "outdated",
            Self::Locked => "locked",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Status {
    pub state: State,
    pub verified: bool,
    pub new_key: bool,
    pub peer_class: Option<PeerClass>,
}

impl Status {
    /// The composer is enabled only when ready (spec §6, §11 decision 2).
    pub fn can_send(self) -> bool {
        self.state == State::Ready
    }
}

pub enum Action {
    Send {
        channel: ChannelId,
        content: String,
    },
    NeedHistory {
        channel: ChannelId,
        before: MessageId,
    },
    StatusChanged {
        channel: ChannelId,
    },
}

pub struct ImageRef {
    pub attachment_id: String,
    pub url: String,
    pub file: PrivateFile,
}

impl Clone for ImageRef {
    fn clone(&self) -> Self {
        Self {
            attachment_id: self.attachment_id.clone(),
            url: self.url.clone(),
            file: self.file.clone(),
        }
    }
}

impl Drop for ImageRef {
    fn drop(&mut self) {
        self.file.key.zeroize();
    }
}

/// A warning line under a private message (spec §6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Warning {
    /// Opened with one of their pending keys.
    UntrustedSender,
    /// Our own message, opened with one of our pending devices.
    UnapprovedDevice,
    /// The same salt appeared in an earlier message.
    Copy,
    /// Posted more than 10 minutes away from when it was written (`sentAt`, Unix seconds).
    WrittenEarlier(u32),
}

impl Warning {
    pub fn code(self) -> &'static str {
        match self {
            Self::UntrustedSender => "untrusted-sender",
            Self::UnapprovedDevice => "unapproved-device",
            Self::Copy => "copy",
            Self::WrittenEarlier(_) => "written-earlier",
        }
    }

    pub fn text(self) -> String {
        match self {
            Self::UntrustedSender => {
                "⚠️ Sent from a new key you haven't accepted. It may not be them.".to_owned()
            }
            Self::UnapprovedDevice => "⚠️ Sent from a device you haven't approved.".to_owned(),
            Self::Copy => {
                "⚠️ A copy of an earlier private message. Discord may have resent it.".to_owned()
            }
            Self::WrittenEarlier(sent_at) => {
                let hours = sent_at / 3_600 % 24;
                let minutes = sent_at / 60 % 60;
                format!(
                    "⚠️ Written {hours:02}:{minutes:02} UTC, not when it appeared. Discord may have resent it."
                )
            }
        }
    }
}

pub struct MessageView {
    pub id: MessageId,
    pub author_id: UserId,
    pub from_me: bool,
    /// The key the message opened with: theirs, ours, or one of our devices.
    pub sender_key: PublicKey,
    pub text: String,
    pub warnings: Vec<Warning>,
    pub trusted: bool,
    pub images: Vec<ImageRef>,
    pub unsupported_video: bool,
}

impl Clone for MessageView {
    fn clone(&self) -> Self {
        Self {
            id: self.id,
            author_id: self.author_id,
            from_me: self.from_me,
            sender_key: self.sender_key,
            text: self.text.clone(),
            warnings: self.warnings.clone(),
            trusted: self.trusted,
            images: self.images.clone(),
            unsupported_video: self.unsupported_video,
        }
    }
}

impl Drop for MessageView {
    fn drop(&mut self) {
        self.text.zeroize();
    }
}

#[derive(Debug, Error)]
pub enum EngineError {
    #[error(transparent)]
    Seal(#[from] SealError),
    #[error("private chat is not enabled for this direct message")]
    NotPrivate,
    #[error("private chat isn't ready: they don't have your key yet, or you don't have theirs")]
    NotReady,
    #[error("this message would need more than 8 recipients")]
    TooManyRecipients,
}

/// What kind of client this engine plays (spec §3 `client`, `host`, `features`).
#[derive(Clone, Copy, Debug)]
pub struct EngineConfig {
    pub client: ClientClass,
    pub host: Host,
    pub features: Features,
    /// Duhcord's "Private chat with Duhcord Companion" (spec §6). Always true for a Companion.
    pub allow_companion_chat: bool,
}

impl EngineConfig {
    pub fn companion(host: Host) -> Self {
        Self {
            client: ClientClass::Companion,
            host,
            features: Features::COMPANION_V1,
            allow_companion_chat: true,
        }
    }

    pub fn duhcord(allow_companion_chat: bool) -> Self {
        Self {
            client: ClientClass::Duhcord,
            host: Host::UNKNOWN,
            features: Features::DUHCORD,
            allow_companion_chat,
        }
    }
}

#[derive(Default)]
struct ChannelState {
    /// Our newest echoed handshake in this DM.
    last_own_handshake: Option<MessageId>,
    /// One of ours is waiting for Discord's echo.
    in_flight: bool,
    /// A handshake to send once the in-flight one is echoed (its `wantsReply`).
    followup: Option<bool>,
    /// Their newest handshake with `wantsReply` that's newer than our last handshake.
    unanswered_request: Option<MessageId>,
    /// Their newest handshake, and whether it came from a newer protocol version.
    newest_peer_handshake: Option<(MessageId, bool)>,
    seen: HashSet<MessageId>,
    requested_history: HashSet<MessageId>,
}

pub struct Engine {
    account: AccountKeys,
    directory: Directory,
    config: EngineConfig,
    dirty: bool,
    locked: bool,
    clock: Option<u64>,
    dms: HashMap<ChannelId, DmInfo>,
    messages: HashMap<ChannelId, BTreeMap<MessageId, WireMessage>>,
    views: HashMap<ChannelId, Vec<MessageView>>,
    requests: HashSet<UserId>,
    channels: HashMap<ChannelId, ChannelState>,
}

impl Engine {
    /// A Companion engine (the default for this crate's app).
    pub fn new(account: AccountKeys, directory: Directory) -> Self {
        Self::with_config(account, directory, EngineConfig::companion(Host::UNKNOWN))
    }

    pub fn with_config(account: AccountKeys, directory: Directory, config: EngineConfig) -> Self {
        Self {
            account,
            directory,
            config,
            dirty: false,
            locked: false,
            clock: None,
            dms: HashMap::new(),
            messages: HashMap::new(),
            views: HashMap::new(),
            requests: HashSet::new(),
            channels: HashMap::new(),
        }
    }

    // ---- accessors -----------------------------------------------------------------------------

    pub fn user_id(&self) -> UserId {
        self.account.user_id
    }

    pub fn public_key(&self) -> PublicKey {
        self.account.public_key()
    }

    pub fn account(&self) -> &AccountKeys {
        &self.account
    }

    pub fn config(&self) -> EngineConfig {
        self.config
    }

    /// The mod our handshakes name (shown to the peer). Set from the plugin's `hello`.
    pub fn set_host(&mut self, host: Host) {
        self.config.host = host;
    }

    /// Duhcord's "Private chat with Duhcord Companion" setting. Changing it is an acceptance change (spec §3 rule 3).
    pub fn set_allow_companion_chat(&mut self, allowed: bool) -> Vec<Action> {
        if self.config.allow_companion_chat == allowed {
            return Vec::new();
        }
        self.config.allow_companion_chat = allowed;
        let channels: Vec<_> = self.dms.keys().copied().collect();
        let mut actions = Vec::new();
        for channel in channels {
            actions.extend(self.acceptance_changed(channel));
        }
        self.rebuild_all_views();
        actions
    }

    /// Fixes "now" for sealing (simulations and tests); `None` uses the system clock.
    pub fn set_clock(&mut self, now: Option<u64>) {
        self.clock = now;
    }

    pub fn dm(&self, channel: ChannelId) -> Option<&DmInfo> {
        self.dms.get(&channel)
    }

    pub fn dms(&self) -> impl Iterator<Item = &DmInfo> {
        self.dms.values()
    }

    pub fn directory(&self) -> &Directory {
        &self.directory
    }

    pub fn directory_dirty(&self) -> bool {
        self.dirty
    }

    pub fn mark_directory_clean(&mut self) {
        self.dirty = false;
    }

    pub fn is_locked(&self) -> bool {
        self.locked
    }

    pub fn set_locked(&mut self, locked: bool) {
        self.locked = locked;
    }

    /// Drops every decrypted view and loaded ciphertext (used when the user locks the session).
    pub fn forget_messages(&mut self) {
        self.views.clear();
        self.messages.clear();
        for state in self.channels.values_mut() {
            state.seen.clear();
        }
    }

    pub fn devices(&self) -> &[OwnDevice] {
        &self.directory.devices
    }

    pub fn view(&self, channel: ChannelId) -> Vec<MessageView> {
        self.views
            .get(&channel)
            .map(|views| views.to_vec())
            .unwrap_or_default()
    }

    /// Every key of the other person, whatever its trust.
    pub fn peer_keys(&self, channel: ChannelId) -> Vec<PeerKey> {
        self.dms
            .get(&channel)
            .and_then(|dm| self.directory.people.get(&dm.peer.id))
            .cloned()
            .unwrap_or_default()
    }

    pub fn pending_keys(&self, channel: ChannelId) -> Vec<PeerKey> {
        self.peer_keys(channel)
            .into_iter()
            .filter(|key| key.trust == Trust::Pending)
            .collect()
    }

    /// Whether this key of theirs counts (spec §6): accepted and not excluded.
    pub fn counts(&self, peer_id: UserId, key: &PeerKey) -> bool {
        key.trust == Trust::Accepted && !self.excluded(peer_id, key)
    }

    /// Accepted, but excluded because it's a Companion key the user (or Duhcord's setting) keeps out.
    pub fn excluded(&self, peer_id: UserId, key: &PeerKey) -> bool {
        key.class == PeerClass::Companion
            && (self.directory.companion_excluded.contains(&peer_id)
                || !self.config.allow_companion_chat)
    }

    pub fn companion_excluded(&self, channel: ChannelId) -> bool {
        self.dms
            .get(&channel)
            .is_some_and(|dm| self.directory.companion_excluded.contains(&dm.peer.id))
    }

    /// The receipt (spec §6): whether the other person has accepted our current key.
    pub fn has_our_key(&self, channel: ChannelId) -> bool {
        self.dms
            .get(&channel)
            .and_then(|dm| self.directory.receipts.get(&dm.peer.id))
            .is_some_and(|receipt| receipt.has_our_key)
    }

    pub fn status(&self, channel: ChannelId) -> Status {
        let Some(dm) = self.dms.get(&channel) else {
            return Status {
                state: State::Off,
                verified: false,
                new_key: false,
                peer_class: None,
            };
        };
        let peer_id = dm.peer.id;
        let counted = self.counted_peer_keys(peer_id);
        let pending = self.pending_keys(channel);
        let peer_class = counted
            .iter()
            .chain(pending.iter())
            .map(|key| key.class)
            .find(|class| *class == PeerClass::Companion)
            .or_else(|| (!counted.is_empty() || !pending.is_empty()).then_some(PeerClass::Duhcord));
        let verified = self.safety_number(channel, &[]).is_some_and(|number| {
            self.directory.verified.get(&peer_id) == Some(&fingerprint(&number))
        });
        let outdated = self
            .channels
            .get(&channel)
            .and_then(|state| state.newest_peer_handshake)
            .is_some_and(|(_, outdated)| outdated);
        let state = if self.locked {
            State::Locked
        } else if self.requests.contains(&peer_id) {
            State::Request
        } else if !self.directory.private_channels.contains(&channel) {
            State::Off
        } else if outdated {
            State::Outdated
        } else if counted.is_empty() {
            State::Waiting
        } else if !self.has_our_key(channel) {
            State::Unconfirmed
        } else {
            State::Ready
        };
        Status {
            state,
            verified,
            new_key: !pending.is_empty(),
            peer_class,
        }
    }

    /// The safety number (spec §8), optionally as it would be with `accepting` (pending keys) counted too.
    pub fn safety_number(&self, channel: ChannelId, accepting: &[PublicKey]) -> Option<String> {
        let dm = self.dms.get(&channel)?;
        let peer_id = dm.peer.id;
        let known = self.directory.people.get(&peer_id)?;
        let mut theirs: Vec<(PublicKey, ClientClass)> = self
            .counted_peer_keys(peer_id)
            .into_iter()
            .map(|key| (key.key, key.class.into()))
            .collect();
        for key in accepting {
            if let Some(peer_key) = known
                .iter()
                .find(|peer_key| peer_key.key == *key && peer_key.trust == Trust::Pending)
            {
                if !theirs.iter().any(|(existing, _)| existing == key) {
                    theirs.push((peer_key.key, peer_key.class.into()));
                }
            }
        }
        if theirs.is_empty() {
            return None;
        }
        Some(protocol::safety_number(&self.our_side(), &theirs))
    }

    /// Our side of the safety number: this device and our approved devices, each with its client.
    pub fn our_side(&self) -> Vec<(PublicKey, ClientClass)> {
        let mut ours = vec![(self.account.public_key(), self.config.client)];
        ours.extend(
            self.directory
                .devices
                .iter()
                .filter(|device| device.trust == Trust::Accepted)
                .map(|device| (device.key, device.class.into())),
        );
        ours
    }

    // ---- input from Discord -------------------------------------------------------------------

    pub fn on_dm(&mut self, dm: DmInfo) -> Vec<Action> {
        if dm.me.id != self.account.user_id || dm.peer.id == dm.me.id {
            return Vec::new();
        }
        let channel = dm.channel_id;
        let changed = self.dms.get(&channel) != Some(&dm);
        self.dms.insert(channel, dm);
        if changed {
            vec![Action::StatusChanged { channel }]
        } else {
            Vec::new()
        }
    }

    /// Reads a DM's loaded messages (any order, any overlap with earlier calls).
    pub fn on_messages(
        &mut self,
        channel: ChannelId,
        messages: Vec<WireMessage>,
        before: Option<MessageId>,
        exhausted: bool,
    ) -> Vec<Action> {
        let Some(dm) = self.dms.get(&channel).cloned() else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        let mut changed = false;
        let own_key = self.account.public_key();
        let now = self.now();
        let counted_before = self.counted_key_set(dm.peer.id);

        let mut ordered = messages;
        ordered.sort_by_key(|message| message.id);
        for message in &ordered {
            let fresh = self
                .channels
                .entry(channel)
                .or_default()
                .seen
                .insert(message.id);
            if !fresh {
                continue;
            }
            let from_me = message.author_id == self.account.user_id;
            let from_peer = message.author_id == dm.peer.id;
            match protocol::kind(&message.content) {
                Kind::Handshake(handshake) if from_me => {
                    if handshake.key == own_key {
                        let state = self.channels.entry(channel).or_default();
                        if state
                            .last_own_handshake
                            .is_none_or(|last| last < message.id)
                        {
                            state.last_own_handshake = Some(message.id);
                            if state
                                .unanswered_request
                                .is_some_and(|request| request < message.id)
                            {
                                state.unanswered_request = None;
                            }
                        }
                        state.in_flight = false;
                        if self.directory.handshake_sent.insert(channel) {
                            self.dirty = true;
                        }
                        if let Some(wants_reply) = self
                            .channels
                            .get_mut(&channel)
                            .and_then(|state| state.followup.take())
                        {
                            actions.extend(self.send_handshake(channel, wants_reply));
                        }
                    } else if self.learn_device(&handshake, now) {
                        changed = true;
                    }
                }
                Kind::Handshake(handshake) if from_peer => {
                    if self.learn_peer_key(dm.peer.id, &handshake, now) {
                        changed = true;
                    }
                    let state = self.channels.entry(channel).or_default();
                    if state
                        .newest_peer_handshake
                        .is_none_or(|(newest, _)| newest < message.id)
                    {
                        state.newest_peer_handshake = Some((message.id, false));
                    }
                    if handshake.wants_reply
                        && state
                            .last_own_handshake
                            .is_none_or(|last| last < message.id)
                    {
                        state.unanswered_request = Some(message.id);
                    }
                    let has = handshake.accepted_key_ids.contains(&key_id(&own_key));
                    if self.record_receipt(dm.peer.id, message.id, has) {
                        changed = true;
                    }
                }
                Kind::NewerHandshake { .. } if from_peer => {
                    let state = self.channels.entry(channel).or_default();
                    if state
                        .newest_peer_handshake
                        .is_none_or(|(newest, _)| newest < message.id)
                    {
                        state.newest_peer_handshake = Some((message.id, true));
                        changed = true;
                    }
                }
                Kind::Encrypted(_) if from_me || from_peer => {
                    self.messages
                        .entry(channel)
                        .or_default()
                        .insert(message.id, message.clone());
                }
                _ => {}
            }
        }

        // An open request: answer it if the user agreed, else show it (spec §3 rule 2). And if the keys of theirs we
        // count changed (a key trusted on first use, or relabelled), tell them (rule 3). One handshake covers both.
        let request = self
            .channels
            .get(&channel)
            .and_then(|state| state.unanswered_request);
        let counted_changed = self.counted_key_set(dm.peer.id) != counted_before;
        let mut answer = false;
        if request.is_some() {
            if self.directory.consented.contains(&dm.peer.id) && !self.locked {
                answer = true;
                if let Some(state) = self.channels.get_mut(&channel) {
                    state.unanswered_request = None;
                }
            } else if self.requests.insert(dm.peer.id) {
                changed = true;
            }
        } else if self.requests.remove(&dm.peer.id) {
            changed = true;
        }
        let tell =
            counted_changed && self.directory.private_channels.contains(&channel) && !self.locked;
        if answer || tell {
            actions.extend(self.queue_handshake(channel, false));
        }

        let before_status = self.status(channel);
        self.rebuild_views(channel);
        if self.status(channel) != before_status {
            changed = true;
        }

        if self.directory.private_channels.contains(&channel) && !exhausted {
            if let Some(before) = before {
                let none_counted = self.counted_peer_keys(dm.peer.id).is_empty();
                let state = self.channels.entry(channel).or_default();
                if none_counted && state.requested_history.insert(before) {
                    actions.push(Action::NeedHistory { channel, before });
                }
            }
        }

        if changed {
            self.dirty = true;
            actions.push(Action::StatusChanged { channel });
        }
        actions
    }

    pub fn on_deleted(&mut self, channel: ChannelId, ids: &[MessageId]) -> Vec<Action> {
        if let Some(messages) = self.messages.get_mut(&channel) {
            for id in ids {
                messages.remove(id);
            }
        }
        self.rebuild_views(channel);
        vec![Action::StatusChanged { channel }]
    }

    /// Our handshake couldn't be posted: it's no longer in flight (spec §3).
    pub fn handshake_send_failed(&mut self, channel: ChannelId) {
        if let Some(state) = self.channels.get_mut(&channel) {
            state.in_flight = false;
        }
    }

    // ---- user actions -------------------------------------------------------------------------

    /// Switches the DM to Private (agreeing to a request) — spec §3 rule 1.
    pub fn agree(&mut self, channel: ChannelId) -> Vec<Action> {
        let Some(dm) = self.dms.get(&channel) else {
            return Vec::new();
        };
        if self.locked {
            return Vec::new();
        }
        let peer_id = dm.peer.id;
        let first_consent = self.directory.consented.insert(peer_id);
        let first_private = self.directory.private_channels.insert(channel);
        self.requests.remove(&peer_id);
        if let Some(state) = self.channels.get_mut(&channel) {
            state.unanswered_request = None;
        }
        self.dirty |= first_consent || first_private;
        let have_theirs = !self.counted_peer_keys(peer_id).is_empty();
        let mut actions = Vec::new();
        if !self.directory.handshake_sent.contains(&channel) || !have_theirs {
            actions.extend(self.queue_handshake(channel, !have_theirs));
        }
        actions.push(Action::StatusChanged { channel });
        actions
    }

    pub fn set_private(&mut self, channel: ChannelId, enabled: bool) -> Vec<Action> {
        if enabled {
            return self.agree(channel);
        }
        if self.directory.private_channels.remove(&channel) {
            self.dirty = true;
        }
        vec![Action::StatusChanged { channel }]
    }

    /// "Re-send my key" (spec §3 rule 4). Always goes out, even if an earlier handshake is still in flight: it's
    /// the recovery path when Discord lost one.
    pub fn resend_key(&mut self, channel: ChannelId) -> Vec<Action> {
        if self.locked || !self.dms.contains_key(&channel) {
            return Vec::new();
        }
        let mut actions = self.send_handshake(channel, true);
        actions.push(Action::StatusChanged { channel });
        actions
    }

    /// Accepts exactly the pending `keys` that were shown. With `compared`, it must equal the safety number shown
    /// with them (and the DM becomes verified); otherwise nothing changes.
    pub fn accept_keys(
        &mut self,
        channel: ChannelId,
        keys: &[PublicKey],
        compared_number: Option<&str>,
    ) -> Result<Vec<Action>, AcceptError> {
        let Some(dm) = self.dms.get(&channel) else {
            return Err(AcceptError::NoChat);
        };
        let peer_id = dm.peer.id;
        let shown: Vec<PublicKey> = self
            .pending_keys(channel)
            .into_iter()
            .filter(|key| keys.contains(&key.key))
            .map(|key| key.key)
            .collect();
        if shown.is_empty() {
            return Err(AcceptError::NothingPending);
        }
        if let Some(compared) = compared_number {
            if self.safety_number(channel, &shown).as_deref() != Some(compared) {
                return Err(AcceptError::Mismatch);
            }
        }
        if let Some(peer_keys) = self.directory.people.get_mut(&peer_id) {
            for peer_key in peer_keys.iter_mut() {
                if peer_key.trust == Trust::Pending && shown.contains(&peer_key.key) {
                    peer_key.trust = Trust::Accepted;
                }
            }
        }
        self.directory.verified.remove(&peer_id);
        self.dirty = true;
        if compared_number.is_some() {
            self.mark_verified(channel);
        }
        self.rebuild_views(channel);
        Ok(self.acceptance_changed(channel))
    }

    pub fn reject_keys(&mut self, channel: ChannelId, keys: &[PublicKey]) -> Vec<Action> {
        let Some(dm) = self.dms.get(&channel) else {
            return Vec::new();
        };
        let peer_id = dm.peer.id;
        let mut changed = false;
        if let Some(peer_keys) = self.directory.people.get_mut(&peer_id) {
            for peer_key in peer_keys.iter_mut() {
                if peer_key.trust == Trust::Pending && keys.contains(&peer_key.key) {
                    peer_key.trust = Trust::Rejected;
                    changed = true;
                }
            }
        }
        if !changed {
            return Vec::new();
        }
        self.directory.verified.remove(&peer_id);
        self.dirty = true;
        self.rebuild_views(channel);
        self.acceptance_changed(channel)
    }

    pub fn set_companion_excluded(&mut self, channel: ChannelId, excluded: bool) -> Vec<Action> {
        let Some(dm) = self.dms.get(&channel) else {
            return Vec::new();
        };
        let peer_id = dm.peer.id;
        let changed = if excluded {
            self.directory.companion_excluded.insert(peer_id)
        } else {
            self.directory.companion_excluded.remove(&peer_id)
        };
        if !changed {
            return Vec::new();
        }
        self.dirty = true;
        self.rebuild_views(channel);
        self.acceptance_changed(channel)
    }

    /// The user confirms the current safety number.
    pub fn mark_verified(&mut self, channel: ChannelId) -> bool {
        let Some(peer_id) = self.dms.get(&channel).map(|dm| dm.peer.id) else {
            return false;
        };
        let Some(number) = self.safety_number(channel, &[]) else {
            return false;
        };
        self.directory
            .verified
            .insert(peer_id, fingerprint(&number));
        self.dirty = true;
        true
    }

    /// Approves or denies one of our own other devices (spec §7). At most 3 approved.
    pub fn set_device(&mut self, key: PublicKey, trust: Trust) -> bool {
        let accepted = self
            .directory
            .devices
            .iter()
            .filter(|device| device.trust == Trust::Accepted && device.key != key)
            .count();
        if trust == Trust::Accepted && accepted >= MAX_ACCEPTED_DEVICES {
            return false;
        }
        let Some(device) = self
            .directory
            .devices
            .iter_mut()
            .find(|device| device.key == key)
        else {
            return false;
        };
        if device.trust == trust || trust == Trust::Pending {
            return false;
        }
        device.trust = trust;
        self.directory.verified.clear();
        self.dirty = true;
        self.rebuild_all_views();
        true
    }

    /// Seals text typed by the user (spec §4, §6). Only in `ready`.
    pub fn seal_text(&mut self, channel: ChannelId, text: &str) -> Result<Action, EngineError> {
        if self.locked || !self.directory.private_channels.contains(&channel) {
            return Err(EngineError::NotPrivate);
        }
        if !self.status(channel).can_send() {
            return Err(EngineError::NotReady);
        }
        let dm = self.dms.get(&channel).ok_or(EngineError::NotPrivate)?;
        let own = self.account.public_key();
        let mut recipients: Vec<PublicKey> = Vec::new();
        for key in self
            .counted_peer_keys(dm.peer.id)
            .into_iter()
            .map(|key| key.key)
            .chain(
                self.directory
                    .devices
                    .iter()
                    .filter(|device| device.trust == Trust::Accepted)
                    .map(|device| device.key),
            )
        {
            if key != own && !recipients.contains(&key) {
                recipients.push(key);
            }
        }
        if recipients.len() > MAX_RECIPIENTS {
            return Err(EngineError::TooManyRecipients);
        }
        recipients.push(own);
        let content = protocol::seal(
            text,
            &[],
            channel,
            self.account.private_key(),
            &recipients,
            self.now().min(u64::from(u32::MAX)) as u32,
        )?;
        if !matches!(protocol::kind(&content), Kind::Encrypted(_)) {
            return Err(EngineError::Seal(SealError::Crypto));
        }
        Ok(Action::Send { channel, content })
    }

    // ---- internals ----------------------------------------------------------------------------

    fn now(&self) -> u64 {
        self.clock.unwrap_or_else(unix_now)
    }

    fn counted_key_set(&self, peer_id: UserId) -> Vec<PublicKey> {
        let mut keys: Vec<_> = self
            .counted_peer_keys(peer_id)
            .into_iter()
            .map(|key| key.key)
            .collect();
        keys.sort_unstable();
        keys
    }

    fn counted_peer_keys(&self, peer_id: UserId) -> Vec<PeerKey> {
        self.directory
            .people
            .get(&peer_id)
            .into_iter()
            .flatten()
            .filter(|key| self.counts(peer_id, key))
            .cloned()
            .collect()
    }

    /// After the user changed which of their keys count: tell them (spec §3 rule 3), if the DM is in Private.
    fn acceptance_changed(&mut self, channel: ChannelId) -> Vec<Action> {
        let mut actions = Vec::new();
        if self.directory.private_channels.contains(&channel) && !self.locked {
            actions.extend(self.queue_handshake(channel, false));
        }
        actions.push(Action::StatusChanged { channel });
        actions
    }

    /// Sends a handshake now, or once the in-flight one is echoed (spec §3: one in flight per DM).
    fn queue_handshake(&mut self, channel: ChannelId, wants_reply: bool) -> Vec<Action> {
        let state = self.channels.entry(channel).or_default();
        if state.in_flight {
            state.followup = Some(state.followup.unwrap_or(false) || wants_reply);
            return Vec::new();
        }
        self.send_handshake(channel, wants_reply)
    }

    fn send_handshake(&mut self, channel: ChannelId, wants_reply: bool) -> Vec<Action> {
        let Some(peer_id) = self.dms.get(&channel).map(|dm| dm.peer.id) else {
            return Vec::new();
        };
        let mut accepted_key_ids: Vec<KeyId> = self
            .counted_peer_keys(peer_id)
            .iter()
            .map(|key| key_id(&key.key))
            .collect();
        accepted_key_ids.sort_unstable();
        accepted_key_ids.dedup();
        accepted_key_ids.truncate(MAX_ACCEPTED_KEY_IDS);
        let content = protocol::handshake_content(&Handshake {
            key: self.account.public_key(),
            wants_reply,
            class: self.config.client,
            host: self.config.host,
            features: self.config.features,
            accepted_key_ids,
        });
        let state = self.channels.entry(channel).or_default();
        state.in_flight = true;
        state.followup = None;
        vec![Action::Send { channel, content }]
    }

    /// Records evidence about whether they have our key, if it's newer than what we had. Returns true if it changed.
    fn record_receipt(
        &mut self,
        peer_id: UserId,
        message_id: MessageId,
        has_our_key: bool,
    ) -> bool {
        let entry = self.directory.receipts.get(&peer_id).copied();
        if entry.is_some_and(|receipt| receipt.message_id >= message_id) {
            return false;
        }
        self.directory.receipts.insert(
            peer_id,
            Receipt {
                message_id,
                has_our_key,
            },
        );
        self.dirty = true;
        entry.is_none_or(|receipt| receipt.has_our_key != has_our_key)
    }

    /// A key from the other person's handshake (spec §6 "Learning a key").
    fn learn_peer_key(&mut self, peer_id: UserId, handshake: &Handshake, now: u64) -> bool {
        if !valid_public_key(handshake.key) {
            return false;
        }
        let keys = self.directory.people.entry(peer_id).or_default();
        let class = PeerClass::from(handshake.class);
        if let Some(existing) = keys.iter_mut().find(|key| key.key == handshake.key) {
            let mut changed = false;
            // A Duhcord key now claiming to be a Companion needs its own approval. A Companion key claiming Duhcord
            // changes nothing: a key never gains Duhcord's label (spec §6).
            if existing.class == PeerClass::Duhcord && class == PeerClass::Companion {
                existing.class = PeerClass::Companion;
                if existing.trust == Trust::Accepted {
                    existing.trust = Trust::Pending;
                }
                self.directory.verified.remove(&peer_id);
                changed = true;
            }
            if existing.features != handshake.features.0 {
                existing.features = handshake.features.0;
                changed = true;
            }
            self.dirty |= changed;
            return changed;
        }
        let trust = if keys.is_empty() && class == PeerClass::Duhcord {
            Trust::Accepted
        } else {
            Trust::Pending
        };
        if trust == Trust::Pending
            && keys
                .iter()
                .filter(|key| key.trust == Trust::Pending)
                .count()
                >= MAX_PENDING_KEYS
        {
            return false;
        }
        keys.push(PeerKey {
            key: handshake.key,
            added: now,
            trust,
            class,
            features: handshake.features.0,
        });
        self.directory.verified.remove(&peer_id);
        self.dirty = true;
        true
    }

    /// Our own handshake with another key: a candidate device (spec §7).
    fn learn_device(&mut self, handshake: &Handshake, now: u64) -> bool {
        if !valid_public_key(handshake.key)
            || self
                .directory
                .devices
                .iter()
                .any(|device| device.key == handshake.key)
            || self
                .directory
                .devices
                .iter()
                .filter(|device| device.trust == Trust::Pending)
                .count()
                >= MAX_PENDING_KEYS
        {
            return false;
        }
        self.directory.devices.push(OwnDevice {
            key: handshake.key,
            added: now,
            trust: Trust::Pending,
            class: handshake.class.into(),
        });
        self.dirty = true;
        true
    }

    fn rebuild_all_views(&mut self) {
        let channels: Vec<_> = self.dms.keys().copied().collect();
        for channel in channels {
            self.rebuild_views(channel);
        }
    }

    fn rebuild_views(&mut self, channel: ChannelId) {
        let Some(dm) = self.dms.get(&channel).cloned() else {
            self.views.remove(&channel);
            return;
        };
        let Some(messages) = self.messages.get(&channel) else {
            self.views.insert(channel, Vec::new());
            return;
        };
        let messages: Vec<_> = messages.values().cloned().collect();
        let own_key = self.account.public_key();
        let own_id = key_id(&own_key);
        let peer_keys = self
            .directory
            .people
            .get(&dm.peer.id)
            .cloned()
            .unwrap_or_default();
        let counted: Vec<PublicKey> = peer_keys
            .iter()
            .filter(|key| self.counts(dm.peer.id, key))
            .map(|key| key.key)
            .collect();
        let pending: Vec<PublicKey> = peer_keys
            .iter()
            .filter(|key| key.trust == Trust::Pending)
            .map(|key| key.key)
            .collect();
        let approved_devices: Vec<PublicKey> = self
            .directory
            .devices
            .iter()
            .filter(|device| device.trust == Trust::Accepted)
            .map(|device| device.key)
            .collect();
        let pending_devices: Vec<PublicKey> = self
            .directory
            .devices
            .iter()
            .filter(|device| device.trust == Trust::Pending)
            .map(|device| device.key)
            .collect();

        let mut views = Vec::new();
        let mut receipts = Vec::new();
        for message in messages {
            let Kind::Encrypted(payload) = protocol::kind(&message.content) else {
                continue;
            };
            let from_me = message.author_id == self.account.user_id;
            let (trusted_senders, untrusted_senders) = if from_me {
                (&approved_devices, &pending_devices)
            } else {
                (&counted, &pending)
            };
            let sender_id: KeyId = payload[2..6].try_into().expect("checked frame shape");
            let mut opened = None;
            if from_me && sender_id == own_id {
                opened = protocol::open(&payload, channel, self.account.private_key(), &[], true)
                    .map(|opened| (opened, own_key, true));
            }
            if opened.is_none() {
                opened = open_with(&payload, channel, &self.account, trusted_senders)
                    .map(|(opened, sender)| (opened, sender, true));
            }
            if opened.is_none() {
                opened = open_with(&payload, channel, &self.account, untrusted_senders)
                    .map(|(opened, sender)| (opened, sender, false));
            }
            let Some((opened, sender_key, trusted)) = opened else {
                continue;
            };
            if !from_me && trusted && opened.recipient_key_ids.contains(&own_id) {
                receipts.push(message.id);
            }
            let mut warnings = Vec::new();
            if !trusted {
                warnings.push(if from_me {
                    Warning::UnapprovedDevice
                } else {
                    Warning::UntrustedSender
                });
            }
            let salt_key = hex_salt(&opened.salt);
            let mut copy = false;
            match self.directory.first_with_salt.get(&salt_key).copied() {
                Some(first) if first.message_id < message.id => copy = true,
                Some(first) if first.message_id == message.id => {}
                _ => {
                    self.directory.first_with_salt.insert(
                        salt_key,
                        ReplayRecord {
                            message_id: message.id,
                        },
                    );
                    self.dirty = true;
                }
            }
            if copy {
                warnings.push(Warning::Copy);
            } else {
                let posted_at = message
                    .edited_at
                    .unwrap_or_else(|| snowflake_time(message.id));
                if (posted_at - i64::from(opened.sent_at)).abs() > REPLAY_TOLERANCE_SECONDS {
                    warnings.push(Warning::WrittenEarlier(opened.sent_at));
                }
            }
            let unsupported_video =
                opened.text.starts_with("\u{1e}film/") || opened.text.starts_with("\u{1e}reel/");
            let text = if unsupported_video {
                "A private video — open it in Duhcord".to_owned()
            } else {
                opened.text.clone()
            };
            let images = opened
                .files
                .iter()
                .enumerate()
                .filter_map(|(index, file)| {
                    let attachment = message.attachments.get(index)?;
                    let valid_image = matches!(
                        file.kind,
                        protocol::FileKind::Jpeg | protocol::FileKind::Png
                    );
                    (valid_image
                        && attachment.filename == "encrypted.bin"
                        && attachment.size == u64::from(file.sealed_length)
                        && allowed_attachment_url(&attachment.url))
                    .then(|| ImageRef {
                        attachment_id: attachment.id.clone(),
                        url: attachment.url.clone(),
                        file: file.clone(),
                    })
                })
                .collect();
            views.push(MessageView {
                id: message.id,
                author_id: message.author_id,
                from_me,
                sender_key,
                text,
                warnings,
                trusted,
                images,
                unsupported_video,
            });
        }
        self.views.insert(channel, views);
        for message_id in receipts {
            self.record_receipt(dm.peer.id, message_id, true);
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AcceptError {
    #[error("this direct message isn't known")]
    NoChat,
    #[error("none of those keys is waiting to be accepted")]
    NothingPending,
    #[error("the safety number you compared doesn't match the one shown with these keys")]
    Mismatch,
}

fn open_with(
    payload: &[u8],
    channel: ChannelId,
    account: &AccountKeys,
    senders: &[PublicKey],
) -> Option<(protocol::Opened, PublicKey)> {
    senders.iter().find_map(|sender| {
        protocol::open(payload, channel, account.private_key(), &[*sender], false)
            .map(|opened| (opened, *sender))
    })
}

fn valid_public_key(key: PublicKey) -> bool {
    let private = x25519_dalek::StaticSecret::from([0x42; 32]);
    let public = x25519_dalek::PublicKey::from(key);
    private.diffie_hellman(&public).was_contributory()
}

fn allowed_attachment_url(value: &str) -> bool {
    Url::parse(value).ok().is_some_and(|url| {
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && matches!(
                url.host_str(),
                Some("cdn.discordapp.com" | "media.discordapp.net")
            )
    })
}

fn fingerprint(number: &str) -> [u8; 32] {
    Sha256::digest(number.as_bytes()).into()
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn snowflake_time(id: MessageId) -> i64 {
    DISCORD_EPOCH_SECONDS + (id >> 22) as i64 / 1000
}

fn hex_salt(salt: &[u8; 16]) -> String {
    salt.iter().map(|byte| format!("{byte:02x}")).collect()
}
