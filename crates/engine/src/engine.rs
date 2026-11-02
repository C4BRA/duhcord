use std::{
    collections::{BTreeMap, HashMap, HashSet},
    time::{SystemTime, UNIX_EPOCH},
};

use duhcord_private_protocol::{
    self as protocol, ClientClass, Features, Handshake, Kind, PrivateFile, PrivateKey, PublicKey,
    SealError,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;
use zeroize::Zeroize;

pub type UserId = u64;
pub type ChannelId = u64;
pub type MessageId = u64;

const MAX_PENDING_KEYS: usize = 4;
const MAX_ACCEPTED_OWN_MACS: usize = 3;
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerKey {
    pub key: PublicKey,
    pub added: u64,
    pub trust: Trust,
    pub class: PeerClass,
    pub features: u16,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnMac {
    pub key: PublicKey,
    pub added: u64,
    pub trust: Trust,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayRecord {
    pub message_id: MessageId,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Directory {
    pub people: HashMap<UserId, Vec<PeerKey>>,
    pub own_macs: Vec<OwnMac>,
    pub consented: HashSet<UserId>,
    pub private_channels: HashSet<ChannelId>,
    pub verified: HashMap<UserId, [u8; 32]>,
    pub first_with_salt: HashMap<String, ReplayRecord>,
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Off,
    Request,
    Waiting,
    Ready,
    Locked,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Status {
    pub state: State,
    pub verified: bool,
    pub new_key: bool,
    pub peer_class: Option<PeerClass>,
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

pub struct MessageView {
    pub id: MessageId,
    pub author_id: UserId,
    pub from_me: bool,
    pub text: String,
    pub warnings: Vec<String>,
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
}

#[derive(Default)]
struct HandshakeState {
    last_own_handshake: Option<MessageId>,
    pending_handshake: bool,
    seen_handshakes: HashSet<MessageId>,
    requested_history: HashSet<MessageId>,
}

pub struct Engine {
    account: AccountKeys,
    directory: Directory,
    dirty: bool,
    locked: bool,
    dms: HashMap<ChannelId, DmInfo>,
    messages: HashMap<ChannelId, BTreeMap<MessageId, WireMessage>>,
    views: HashMap<ChannelId, Vec<MessageView>>,
    requests: HashSet<UserId>,
    handshakes: HashMap<ChannelId, HandshakeState>,
}

impl Engine {
    pub fn new(account: AccountKeys, directory: Directory) -> Self {
        Self {
            account,
            directory,
            dirty: false,
            locked: false,
            dms: HashMap::new(),
            messages: HashMap::new(),
            views: HashMap::new(),
            requests: HashSet::new(),
            handshakes: HashMap::new(),
        }
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

    pub fn set_locked(&mut self, locked: bool) {
        self.locked = locked;
    }

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
        let now = unix_now();

        let mut ordered = messages;
        ordered.sort_by_key(|message| message.id);
        for message in &ordered {
            let kind = protocol::kind(&message.content);
            if let Kind::Handshake(handshake) = kind {
                let seen = {
                    let state = self.handshakes.entry(channel).or_default();
                    !state.seen_handshakes.insert(message.id)
                };
                if seen {
                    continue;
                }
                if message.author_id == self.account.user_id {
                    if handshake.key == own_key {
                        let state = self.handshakes.entry(channel).or_default();
                        state.pending_handshake = false;
                        state.last_own_handshake = Some(message.id);
                    } else if handshake.class == ClientClass::Duhcord
                        && self.learn_own_mac(handshake.key, now)
                    {
                        changed = true;
                    }
                    continue;
                }
                if message.author_id != dm.peer.id {
                    continue;
                }
                if self.learn_peer_key_for(dm.peer.id, handshake, now) {
                    changed = true;
                }
                let unanswered = handshake.wants_reply
                    && self
                        .handshakes
                        .get(&channel)
                        .and_then(|state| state.last_own_handshake)
                        .is_none_or(|last| last < message.id);
                if unanswered {
                    if self.directory.consented.contains(&dm.peer.id) {
                        let pending = self
                            .handshakes
                            .get(&channel)
                            .is_some_and(|state| state.pending_handshake);
                        if !pending {
                            actions.extend(self.make_handshake(channel, false));
                        }
                    } else if self.requests.insert(dm.peer.id) {
                        changed = true;
                    }
                }
            }
        }

        let channel_messages = self.messages.entry(channel).or_default();
        for message in ordered {
            if matches!(protocol::kind(&message.content), Kind::Encrypted(_)) {
                channel_messages.insert(message.id, message);
            }
        }
        self.rebuild_views(channel);

        if self.directory.private_channels.contains(&channel) && !exhausted {
            if let Some(before) = before {
                let should_request = !self
                    .handshakes
                    .get(&channel)
                    .is_some_and(|state| state.requested_history.contains(&before))
                    && self.accepted_peer_keys(dm.peer.id).is_empty();
                if should_request {
                    self.handshakes
                        .entry(channel)
                        .or_default()
                        .requested_history
                        .insert(before);
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
        let have_key = !self.accepted_peer_keys(peer_id).is_empty();
        self.dirty |= first_consent || first_private;
        let mut actions = Vec::new();
        if first_consent || !have_key {
            actions.extend(self.make_handshake(channel, !have_key));
        }
        actions.push(Action::StatusChanged { channel });
        actions
    }

    pub fn seal_text(&mut self, channel: ChannelId, text: &str) -> Result<Action, EngineError> {
        if self.locked || !self.directory.private_channels.contains(&channel) {
            return Err(EngineError::NotPrivate);
        }
        let dm = self.dms.get(&channel).ok_or(EngineError::NotPrivate)?;
        let mut recipients: Vec<PublicKey> = self
            .accepted_peer_keys(dm.peer.id)
            .into_iter()
            .map(|key| key.key)
            .collect();
        recipients.push(self.account.public_key());
        recipients.extend(
            self.directory
                .own_macs
                .iter()
                .filter(|mac| mac.trust == Trust::Accepted)
                .map(|mac| mac.key),
        );
        let content = protocol::seal(
            text,
            &[],
            channel,
            self.account.private_key(),
            &recipients,
            unix_now().min(u64::from(u32::MAX)) as u32,
        )?;
        if !matches!(protocol::kind(&content), Kind::Encrypted(_)) {
            return Err(EngineError::Seal(SealError::Crypto));
        }
        Ok(Action::Send { channel, content })
    }

    pub fn view(&self, channel: ChannelId) -> Vec<MessageView> {
        self.views
            .get(&channel)
            .map(|views| views.to_vec())
            .unwrap_or_default()
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
        let pending = self.pending_keys(channel);
        let accepted = self.accepted_peer_keys(dm.peer.id);
        let peer_class = accepted
            .iter()
            .map(|key| key.class)
            .chain(pending.iter().map(|key| key.class))
            .find(|class| *class == PeerClass::Companion)
            .or_else(|| {
                (!accepted.is_empty() || !pending.is_empty()).then_some(PeerClass::Duhcord)
            });
        let verified = self
            .safety_number(channel, &[])
            .map(|number| self.directory.verified.get(&dm.peer.id) == Some(&fingerprint(&number)))
            .unwrap_or(false);
        let state = if self.locked {
            State::Locked
        } else if self.requests.contains(&dm.peer.id) {
            State::Request
        } else if !self.directory.private_channels.contains(&channel) {
            State::Off
        } else if accepted.is_empty() {
            State::Waiting
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

    pub fn safety_number(&self, channel: ChannelId, accepting: &[PublicKey]) -> Option<String> {
        let dm = self.dms.get(&channel)?;
        let mut our_keys = vec![(self.account.public_key(), ClientClass::Companion)];
        our_keys.extend(
            self.directory
                .own_macs
                .iter()
                .filter(|mac| mac.trust == Trust::Accepted)
                .map(|mac| (mac.key, ClientClass::Duhcord)),
        );
        let known = self.directory.people.get(&dm.peer.id)?;
        let mut their_keys: Vec<_> = self
            .accepted_peer_keys(dm.peer.id)
            .into_iter()
            .map(|key| (key.key, ClientClass::from(key.class)))
            .collect();
        for key in accepting {
            if let Some(peer_key) = known.iter().find(|peer_key| peer_key.key == *key) {
                if peer_key.trust != Trust::Rejected
                    && !their_keys.iter().any(|(existing, _)| existing == key)
                {
                    their_keys.push((peer_key.key, ClientClass::from(peer_key.class)));
                }
            }
        }
        Some(protocol::safety_number(&our_keys, &their_keys))
    }

    pub fn pending_keys(&self, channel: ChannelId) -> Vec<PeerKey> {
        let Some(dm) = self.dms.get(&channel) else {
            return Vec::new();
        };
        self.directory
            .people
            .get(&dm.peer.id)
            .into_iter()
            .flatten()
            .filter(|key| key.trust == Trust::Pending)
            .cloned()
            .collect()
    }

    pub fn accept_keys(
        &mut self,
        channel: ChannelId,
        keys: &[PublicKey],
        compared_number: Option<&str>,
    ) -> bool {
        let Some(dm) = self.dms.get(&channel) else {
            return false;
        };
        let peer_id = dm.peer.id;
        if let Some(compared) = compared_number {
            let candidate: Vec<_> = self
                .pending_keys(channel)
                .into_iter()
                .filter(|key| keys.contains(&key.key))
                .map(|key| (key.key, ClientClass::from(key.class)))
                .collect();
            if !candidate.is_empty() {
                let mut our_keys = vec![(self.account.public_key(), ClientClass::Companion)];
                our_keys.extend(
                    self.directory
                        .own_macs
                        .iter()
                        .filter(|mac| mac.trust == Trust::Accepted)
                        .map(|mac| (mac.key, ClientClass::Duhcord)),
                );
                let mut theirs: Vec<_> = self
                    .accepted_peer_keys(peer_id)
                    .into_iter()
                    .map(|key| (key.key, ClientClass::from(key.class)))
                    .collect();
                theirs.extend(candidate);
                if protocol::safety_number(&our_keys, &theirs) != compared {
                    return false;
                }
            }
        }
        let mut changed = false;
        if let Some(peer_keys) = self.directory.people.get_mut(&peer_id) {
            for peer_key in peer_keys {
                if peer_key.trust == Trust::Pending && keys.contains(&peer_key.key) {
                    peer_key.trust = Trust::Accepted;
                    changed = true;
                }
            }
        }
        if !changed {
            return false;
        }
        self.directory.verified.remove(&peer_id);
        self.dirty = true;
        self.rebuild_views(channel);
        if compared_number.is_some() {
            self.mark_verified(channel)
        } else {
            true
        }
    }

    pub fn reject_keys(&mut self, channel: ChannelId, keys: &[PublicKey]) {
        let Some(dm) = self.dms.get(&channel) else {
            return;
        };
        let peer_id = dm.peer.id;
        let mut changed = false;
        if let Some(peer_keys) = self.directory.people.get_mut(&peer_id) {
            for peer_key in peer_keys {
                if peer_key.trust == Trust::Pending && keys.contains(&peer_key.key) {
                    peer_key.trust = Trust::Rejected;
                    changed = true;
                }
            }
        }
        if changed {
            self.directory.verified.remove(&peer_id);
            self.dirty = true;
            self.rebuild_views(channel);
        }
    }

    pub fn mark_verified(&mut self, channel: ChannelId) -> bool {
        let Some(dm) = self.dms.get(&channel) else {
            return false;
        };
        let Some(number) = self.safety_number(channel, &[]) else {
            return false;
        };
        self.directory
            .verified
            .insert(dm.peer.id, fingerprint(&number));
        self.dirty = true;
        true
    }

    pub fn set_private(&mut self, channel: ChannelId, enabled: bool) {
        if enabled {
            let _ = self.agree(channel);
        } else if self.directory.private_channels.remove(&channel) {
            self.dirty = true;
        }
    }

    pub fn pending_own_macs(&self) -> Vec<OwnMac> {
        self.directory
            .own_macs
            .iter()
            .filter(|mac| mac.trust == Trust::Pending)
            .cloned()
            .collect()
    }

    pub fn accept_own_mac(&mut self, key: PublicKey) -> bool {
        let accepted_count = self
            .directory
            .own_macs
            .iter()
            .filter(|mac| mac.trust == Trust::Accepted)
            .count();
        let Some(mac) = self
            .directory
            .own_macs
            .iter_mut()
            .find(|mac| mac.key == key && mac.trust == Trust::Pending)
        else {
            return false;
        };
        if accepted_count >= MAX_ACCEPTED_OWN_MACS {
            return false;
        }
        mac.trust = Trust::Accepted;
        self.directory.verified.clear();
        self.dirty = true;
        self.rebuild_all_views();
        true
    }

    pub fn reject_own_mac(&mut self, key: PublicKey) -> bool {
        let Some(mac) = self
            .directory
            .own_macs
            .iter_mut()
            .find(|mac| mac.key == key && mac.trust == Trust::Pending)
        else {
            return false;
        };
        mac.trust = Trust::Rejected;
        self.dirty = true;
        self.rebuild_all_views();
        true
    }

    pub fn handshake_send_failed(&mut self, channel: ChannelId) {
        if let Some(state) = self.handshakes.get_mut(&channel) {
            state.pending_handshake = false;
        }
    }

    fn accepted_peer_keys(&self, peer_id: UserId) -> Vec<PeerKey> {
        self.directory
            .people
            .get(&peer_id)
            .into_iter()
            .flatten()
            .filter(|key| key.trust == Trust::Accepted)
            .cloned()
            .collect()
    }

    fn learn_peer_key_for(&mut self, peer_id: UserId, handshake: Handshake, now: u64) -> bool {
        if !valid_public_key(handshake.key) {
            return false;
        }
        let keys = self.directory.people.entry(peer_id).or_default();
        if let Some(existing) = keys.iter_mut().find(|key| key.key == handshake.key) {
            if handshake.class != ClientClass::Companion {
                return false;
            }
            let mut changed = false;
            if existing.class != PeerClass::Companion {
                existing.class = PeerClass::Companion;
                if existing.trust == Trust::Accepted {
                    existing.trust = Trust::Pending;
                }
                changed = true;
            }
            if existing.features != handshake.features.0 {
                existing.features = handshake.features.0;
                changed = true;
            }
            if changed {
                self.directory.verified.remove(&peer_id);
            }
            return changed;
        }
        let first = keys.is_empty();
        let trust = if first && handshake.class == ClientClass::Duhcord {
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
            class: handshake.class.into(),
            features: handshake.features.0,
        });
        self.directory.verified.remove(&peer_id);
        true
    }

    fn learn_own_mac(&mut self, key: PublicKey, now: u64) -> bool {
        if !valid_public_key(key)
            || self.directory.own_macs.iter().any(|mac| mac.key == key)
            || self
                .directory
                .own_macs
                .iter()
                .filter(|mac| mac.trust == Trust::Pending)
                .count()
                >= MAX_PENDING_KEYS
        {
            return false;
        }
        self.directory.own_macs.push(OwnMac {
            key,
            added: now,
            trust: Trust::Pending,
        });
        true
    }

    fn make_handshake(&mut self, channel: ChannelId, wants_reply: bool) -> Vec<Action> {
        let state = self.handshakes.entry(channel).or_default();
        if state.pending_handshake {
            return Vec::new();
        }
        state.pending_handshake = true;
        let content = protocol::handshake_content(&Handshake {
            key: self.account.public_key(),
            wants_reply,
            class: ClientClass::Companion,
            host: protocol::Host::Unknown,
            features: Features::COMPANION_V1,
        });
        if matches!(protocol::kind(&content), Kind::Handshake(_)) {
            vec![Action::Send { channel, content }]
        } else {
            state.pending_handshake = false;
            Vec::new()
        }
    }

    fn rebuild_all_views(&mut self) {
        let channels: Vec<_> = self.messages.keys().copied().collect();
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
        let mut views = Vec::new();
        for message in messages {
            let Kind::Encrypted(payload) = protocol::kind(&message.content) else {
                continue;
            };
            let from_me = message.author_id == self.account.user_id;
            if !from_me && message.author_id != dm.peer.id {
                continue;
            }
            let (trusted_senders, pending_senders, from_self) = if from_me {
                (
                    self.directory
                        .own_macs
                        .iter()
                        .filter(|mac| mac.trust == Trust::Accepted)
                        .map(|mac| mac.key)
                        .collect::<Vec<_>>(),
                    self.directory
                        .own_macs
                        .iter()
                        .filter(|mac| mac.trust == Trust::Pending)
                        .map(|mac| mac.key)
                        .collect::<Vec<_>>(),
                    true,
                )
            } else {
                let keys = self
                    .directory
                    .people
                    .get(&dm.peer.id)
                    .cloned()
                    .unwrap_or_default();
                (
                    keys.iter()
                        .filter(|key| key.trust == Trust::Accepted)
                        .map(|key| key.key)
                        .collect(),
                    keys.iter()
                        .filter(|key| key.trust == Trust::Pending)
                        .map(|key| key.key)
                        .collect(),
                    false,
                )
            };
            let mut opened = protocol::open(
                &payload,
                channel,
                self.account.private_key(),
                &trusted_senders,
                from_self,
            )
            .map(|opened| (opened, true));
            if opened.is_none() && !pending_senders.is_empty() {
                opened = protocol::open(
                    &payload,
                    channel,
                    self.account.private_key(),
                    &pending_senders,
                    false,
                )
                .map(|opened| (opened, false));
            }
            let Some((opened, trusted)) = opened else {
                continue;
            };
            let mut warnings = Vec::new();
            if !trusted {
                warnings.push(if from_me {
                    "⚠️ *Sent from a Mac you haven't approved in Settings.*".to_owned()
                } else {
                    "⚠️ *Sent from a new key you haven't accepted. It may not be them.*".to_owned()
                });
            }
            let salt_key = hex_salt(&opened.salt);
            let replay = self.directory.first_with_salt.get(&salt_key).copied();
            if let Some(first) = replay {
                if first.message_id != message.id && first.message_id < message.id {
                    warnings.push(
                        "⚠️ *A copy of an earlier private message. Discord may have resent it.*"
                            .to_owned(),
                    );
                } else if message.id < first.message_id {
                    self.directory.first_with_salt.insert(
                        salt_key.clone(),
                        ReplayRecord {
                            message_id: message.id,
                        },
                    );
                    self.dirty = true;
                }
            } else {
                self.directory.first_with_salt.insert(
                    salt_key,
                    ReplayRecord {
                        message_id: message.id,
                    },
                );
                self.dirty = true;
            }
            if warnings
                .iter()
                .all(|warning| !warning.contains("A copy of an earlier private message"))
            {
                let posted_at = message
                    .edited_at
                    .unwrap_or_else(|| snowflake_time(message.id));
                if (posted_at - i64::from(opened.sent_at)).abs() > REPLAY_TOLERANCE_SECONDS {
                    let hours = opened.sent_at / 3_600 % 24;
                    let minutes = opened.sent_at / 60 % 60;
                    warnings.push(format!(
                        "⚠️ *Written {hours:02}:{minutes:02} UTC, not when it appeared. Discord may have resent it.*"
                    ));
                }
            }
            let unsupported_video =
                opened.text.starts_with("\u{1e}film/") || opened.text.starts_with("\u{1e}reel/");
            let text = if unsupported_video {
                "A private video — open it in Duhcord".to_owned()
            } else {
                opened.text
            };
            let images = opened
                .files
                .into_iter()
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
                        file,
                    })
                })
                .collect();
            views.push(MessageView {
                id: message.id,
                author_id: message.author_id,
                from_me,
                text,
                warnings,
                trusted,
                images,
                unsupported_video,
            });
        }
        self.views.insert(channel, views);
    }
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
