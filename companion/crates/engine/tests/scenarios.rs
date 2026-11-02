//! Runs the shared behaviour scenarios (spec/SCENARIOS.md) against this engine. Duhcord's XCTest runner reads the
//! same files; both must pass every one.

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use duhcord_companion_engine::{
    AccountKeys, Action, ChannelId, DmInfo, Engine, EngineConfig, EngineError, MessageId, Trust,
    UserId, UserInfo, WireMessage,
};
use duhcord_private_protocol::{
    self as protocol, dense_text, handshake_frame, key_id, ClientClass, Features, Handshake, Host,
    Kind, PublicKey, NOTICE, PREFIX,
};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

const CHANNEL: ChannelId = 1_100_000_000_000_000_001;
const START: u64 = 1_700_000_000;
const DISCORD_EPOCH_MS: u64 = 1_420_070_400_000;
const REQUIRED: [&str; 14] = [
    "duhcord-pair",
    "duhcord-and-companion",
    "companion-chat-off",
    "dropped-handshake",
    "relabel-first-handshake",
    "relabel-known-key",
    "new-key",
    "reject",
    "own-devices",
    "exclude-companion",
    "replay-and-delay",
    "outdated",
    "pending-limit",
    "too-many-recipients",
];

fn person_id(person: &str) -> UserId {
    match person {
        "alice" => 1001,
        "bob" => 1002,
        other => panic!("unknown person {other}"),
    }
}

fn other_person(person: &str) -> &'static str {
    if person == "alice" {
        "bob"
    } else {
        "alice"
    }
}

fn user(person: &str) -> UserInfo {
    UserInfo {
        id: person_id(person),
        username: person.to_owned(),
        global_name: None,
        avatar_url: None,
    }
}

fn device_private_key(name: &str) -> [u8; 32] {
    Sha256::digest(format!("duhcord-vector-{name}").as_bytes()).into()
}

fn device_public_key(name: &str) -> PublicKey {
    protocol::PrivateKey::from_bytes(device_private_key(name)).public_key()
}

struct Device {
    person: String,
    engine: Engine,
    /// (global send order, content)
    outbox: Vec<(u64, String)>,
    refused: Option<String>,
}

struct Sim {
    name: String,
    devices: BTreeMap<String, Device>,
    log: Vec<WireMessage>,
    time: u64,
    counter: u64,
    send_order: u64,
    /// key ID → device name, for reading receipts back as names.
    names: BTreeMap<[u8; 4], String>,
}

impl Sim {
    fn new(name: &str, devices: &Map<String, Value>) -> Self {
        let mut sim = Sim {
            name: name.to_owned(),
            devices: BTreeMap::new(),
            log: Vec::new(),
            time: START,
            counter: 0,
            send_order: 0,
            names: BTreeMap::new(),
        };
        for (device_name, spec) in devices {
            let person = spec["person"].as_str().expect("device person").to_owned();
            let config = match spec["client"].as_str().expect("device client") {
                "duhcord" => EngineConfig::duhcord(true),
                "companion" => EngineConfig::companion(match spec["host"].as_str() {
                    Some("vencord") => Host::VENCORD,
                    Some("vesktop") => Host::VESKTOP,
                    Some("replugged") => Host::REPLUGGED,
                    Some("betterdiscord") => Host::BETTERDISCORD,
                    Some("dorion") => Host::DORION,
                    _ => Host::UNKNOWN,
                }),
                other => panic!("{name}: unknown client {other}"),
            };
            let account =
                AccountKeys::new(person_id(&person), device_private_key(device_name), [0; 32]);
            let engine = Engine::with_config(account, Default::default(), config);
            sim.names
                .insert(key_id(&device_public_key(device_name)), device_name.clone());
            sim.devices.insert(
                device_name.clone(),
                Device {
                    person,
                    engine,
                    outbox: Vec::new(),
                    refused: None,
                },
            );
        }
        sim.sync();
        sim
    }

    fn snowflake(&mut self) -> MessageId {
        self.counter += 1;
        ((self.time * 1000 - DISCORD_EPOCH_MS) << 22) + self.counter
    }

    fn take(&mut self, device: &str, actions: Vec<Action>) {
        for action in actions {
            if let Action::Send { content, .. } = action {
                self.send_order += 1;
                let order = self.send_order;
                self.devices
                    .get_mut(device)
                    .unwrap_or_else(|| panic!("{}: unknown device {device}", self.name))
                    .outbox
                    .push((order, content));
            }
        }
    }

    /// Every device reads the whole log, as if Discord loaded the DM.
    fn sync(&mut self) {
        let names: Vec<String> = self.devices.keys().cloned().collect();
        for name in names {
            let log = self.log.clone();
            let time = self.time;
            let device = self.devices.get_mut(&name).expect("device");
            let me = device.person.clone();
            device.engine.set_clock(Some(time));
            let mut actions = device.engine.on_dm(DmInfo {
                channel_id: CHANNEL,
                peer: user(other_person(&me)),
                me: user(&me),
            });
            actions.extend(device.engine.on_messages(CHANNEL, log, None, true));
            self.take(&name, actions);
        }
    }

    fn device(&mut self, step: &Value) -> (String, &mut Device) {
        let name = step["device"].as_str().expect("step device").to_owned();
        let time = self.time;
        let sim_name = self.name.clone();
        let device = self
            .devices
            .get_mut(&name)
            .unwrap_or_else(|| panic!("{sim_name}: unknown device {name}"));
        device.engine.set_clock(Some(time));
        (name, device)
    }

    fn keys(step: &Value, field: &str) -> Vec<PublicKey> {
        step[field]
            .as_array()
            .unwrap_or_else(|| panic!("step needs `{field}`"))
            .iter()
            .map(|name| device_public_key(name.as_str().expect("device name")))
            .collect()
    }

    fn act(&mut self, step: &Value) {
        let action = step["do"].as_str().expect("action");
        match action {
            "setPrivate" => {
                let on = step["on"].as_bool().expect("on");
                let (name, device) = self.device(step);
                let actions = device.engine.set_private(CHANNEL, on);
                self.take(&name, actions);
            }
            "resendKey" => {
                let (name, device) = self.device(step);
                let actions = device.engine.resend_key(CHANNEL);
                self.take(&name, actions);
            }
            "accept" => {
                let keys = Self::keys(step, "keys");
                let compared = step
                    .get("compared")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let (name, device) = self.device(step);
                let compared = match compared.as_deref() {
                    Some("shown") => device.engine.safety_number(CHANNEL, &keys),
                    other => other.map(str::to_owned),
                };
                if let Ok(actions) = device
                    .engine
                    .accept_keys(CHANNEL, &keys, compared.as_deref())
                {
                    self.take(&name, actions);
                }
            }
            "reject" => {
                let keys = Self::keys(step, "keys");
                let (name, device) = self.device(step);
                let actions = device.engine.reject_keys(CHANNEL, &keys);
                self.take(&name, actions);
            }
            "markVerified" => {
                let (_, device) = self.device(step);
                device.engine.mark_verified(CHANNEL);
            }
            "excludeCompanion" => {
                let on = step["on"].as_bool().expect("on");
                let (name, device) = self.device(step);
                let actions = device.engine.set_companion_excluded(CHANNEL, on);
                self.take(&name, actions);
            }
            "allowCompanionChat" => {
                let on = step["on"].as_bool().expect("on");
                let (name, device) = self.device(step);
                if device.engine.config().client == ClientClass::Duhcord {
                    let actions = device.engine.set_allow_companion_chat(on);
                    self.take(&name, actions);
                }
            }
            "setDevice" => {
                let key = device_public_key(step["key"].as_str().expect("key"));
                let trust = match step["trust"].as_str().expect("trust") {
                    "accepted" => Trust::Accepted,
                    "rejected" => Trust::Rejected,
                    other => panic!("unknown trust {other}"),
                };
                let (_, device) = self.device(step);
                device.engine.set_device(key, trust);
            }
            "send" => {
                let text = step["text"].as_str().expect("text").to_owned();
                let (name, device) = self.device(step);
                match device.engine.seal_text(CHANNEL, &text) {
                    Ok(action) => {
                        device.refused = None;
                        self.take(&name, vec![action]);
                    }
                    Err(EngineError::NotReady) | Err(EngineError::NotPrivate) => {
                        device.refused = Some("not-ready".to_owned())
                    }
                    Err(EngineError::TooManyRecipients) => {
                        device.refused = Some("too-many-recipients".to_owned())
                    }
                    Err(error) => panic!("{}: send failed: {error}", self.name),
                }
            }
            "deliver" => {
                let mut queued: Vec<(u64, String, String)> = Vec::new();
                for device in self.devices.values_mut() {
                    for (order, content) in device.outbox.drain(..) {
                        queued.push((order, device.person.clone(), content));
                    }
                }
                queued.sort_by_key(|(order, _, _)| *order);
                for (_, person, content) in queued {
                    let id = self.snowflake();
                    self.log.push(WireMessage {
                        id,
                        author_id: person_id(&person),
                        content,
                        edited_at: None,
                        attachments: Vec::new(),
                    });
                    self.time += 1;
                }
            }
            "drop" => {
                let (_, device) = self.device(step);
                device.outbox.clear();
            }
            "relabel" => {
                let client = step["client"].as_u64().expect("client") as u8;
                let (_, device) = self.device(step);
                for (_, content) in device.outbox.iter_mut() {
                    if let Kind::Handshake(_) = protocol::kind(content) {
                        let line = content.rsplit('\n').next().expect("line");
                        let mut frame = dense_text::decode(&line[PREFIX.len()..]).expect("frame");
                        frame[3] = client;
                        *content = format!("{NOTICE}\n{PREFIX}{}", dense_text::encode(&frame));
                    }
                }
            }
            "replay" => {
                let index = step["index"].as_i64().expect("index");
                let position = if index < 0 {
                    self.log.len() as i64 + index
                } else {
                    index
                } as usize;
                let mut copy = self.log[position].clone();
                copy.id = self.snowflake();
                self.time += 1;
                self.log.push(copy);
            }
            "inject" => {
                let person = step["person"].as_str().expect("person");
                let fields = &step["handshake"];
                let handshake = Handshake {
                    key: device_public_key(fields["key"].as_str().expect("key")),
                    wants_reply: fields["wantsReply"].as_bool().unwrap_or(false),
                    class: ClientClass::from_byte(fields["client"].as_u64().unwrap_or(0) as u8)
                        .expect("client"),
                    host: Host(fields["host"].as_u64().unwrap_or(0) as u8),
                    features: Features(fields["features"].as_u64().unwrap_or(0x030F) as u16),
                    accepted_key_ids: fields["acceptedKeys"]
                        .as_array()
                        .map(|names| {
                            names
                                .iter()
                                .map(|name| {
                                    key_id(&device_public_key(name.as_str().expect("name")))
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                };
                let mut frame = handshake_frame(&handshake);
                frame[2] = fields["version"].as_u64().unwrap_or(3) as u8;
                let id = self.snowflake();
                self.log.push(WireMessage {
                    id,
                    author_id: person_id(person),
                    content: format!("{NOTICE}\n{PREFIX}{}", dense_text::encode(&frame)),
                    edited_at: None,
                    attachments: Vec::new(),
                });
                self.time += 1;
            }
            "delay" => self.time += step["seconds"].as_u64().expect("seconds"),
            other => panic!("{}: unknown action {other}", self.name),
        }
    }

    fn check(&self, index: usize, expect: &Map<String, Value>) {
        for (device_name, wanted) in expect {
            let at = format!("{} step {index}, {device_name}", self.name);
            let device = self
                .devices
                .get(device_name)
                .unwrap_or_else(|| panic!("{at}: unknown device"));
            let engine = &device.engine;
            let status = engine.status(CHANNEL);
            let wanted = wanted
                .as_object()
                .unwrap_or_else(|| panic!("{at}: expect an object"));
            for (field, value) in wanted {
                match field.as_str() {
                    "state" => assert_eq!(
                        status.state.as_str(),
                        value.as_str().unwrap(),
                        "{at}: state"
                    ),
                    "newKey" => {
                        assert_eq!(status.new_key, value.as_bool().unwrap(), "{at}: newKey")
                    }
                    "verified" => {
                        assert_eq!(status.verified, value.as_bool().unwrap(), "{at}: verified")
                    }
                    "canSend" => {
                        assert_eq!(status.can_send(), value.as_bool().unwrap(), "{at}: canSend")
                    }
                    "hasOurKey" => {
                        assert_eq!(
                            engine.has_our_key(CHANNEL),
                            value.as_bool().unwrap(),
                            "{at}: hasOurKey"
                        )
                    }
                    "keys" => {
                        let peer_id = person_id(other_person(&device.person));
                        let keys = engine.peer_keys(CHANNEL);
                        for (name, expected) in value.as_object().unwrap() {
                            let key = device_public_key(name);
                            let actual = match keys.iter().find(|peer_key| peer_key.key == key) {
                                None => "unknown",
                                Some(peer_key)
                                    if peer_key.trust == Trust::Accepted
                                        && engine.excluded(peer_id, peer_key) =>
                                {
                                    "excluded"
                                }
                                Some(peer_key) => trust_name(peer_key.trust),
                            };
                            assert_eq!(actual, expected.as_str().unwrap(), "{at}: key {name}");
                        }
                    }
                    "devices" => {
                        for (name, expected) in value.as_object().unwrap() {
                            let key = device_public_key(name);
                            let actual = engine
                                .devices()
                                .iter()
                                .find(|own| own.key == key)
                                .map_or("unknown", |own| trust_name(own.trust));
                            assert_eq!(actual, expected.as_str().unwrap(), "{at}: device {name}");
                        }
                    }
                    "outbox" => {
                        let expected = value.as_array().unwrap();
                        assert_eq!(
                            device.outbox.len(),
                            expected.len(),
                            "{at}: outbox length {:?}",
                            self.describe_outbox(device)
                        );
                        for (item, (_, content)) in expected.iter().zip(&device.outbox) {
                            self.check_outgoing(&at, item, content);
                        }
                    }
                    "messages" => {
                        let views = engine.view(CHANNEL);
                        let expected = value.as_array().unwrap();
                        let actual: Vec<String> = views
                            .iter()
                            .map(|view| {
                                format!(
                                    "{}: {} {:?}",
                                    self.names
                                        .get(&key_id(&view.sender_key))
                                        .cloned()
                                        .unwrap_or_else(|| "?".into()),
                                    view.text,
                                    view.warnings.iter().map(|w| w.code()).collect::<Vec<_>>()
                                )
                            })
                            .collect();
                        assert_eq!(views.len(), expected.len(), "{at}: messages {actual:?}");
                        for (view, item) in views.iter().zip(expected) {
                            let from = item["from"].as_str().unwrap();
                            assert_eq!(
                                self.names
                                    .get(&key_id(&view.sender_key))
                                    .map(String::as_str),
                                Some(from),
                                "{at}: message sender {actual:?}"
                            );
                            assert_eq!(
                                view.text,
                                item["text"].as_str().unwrap(),
                                "{at}: message text"
                            );
                            if let Some(warnings) = item.get("warnings") {
                                let codes: Vec<&str> =
                                    view.warnings.iter().map(|w| w.code()).collect();
                                let wanted: Vec<&str> = warnings
                                    .as_array()
                                    .unwrap()
                                    .iter()
                                    .map(|w| w.as_str().unwrap())
                                    .collect();
                                assert_eq!(codes, wanted, "{at}: warnings on \"{}\"", view.text);
                            }
                        }
                    }
                    "sendRefused" => {
                        let expected = value.as_str().map(str::to_owned);
                        assert_eq!(device.refused, expected, "{at}: sendRefused");
                    }
                    "safetyNumber" => {
                        let mine = engine.safety_number(CHANNEL, &[]);
                        let object = value.as_object().unwrap();
                        let (relation, other) = object.iter().next().unwrap();
                        if relation == "none" {
                            assert!(mine.is_none(), "{at}: expected no safety number");
                            continue;
                        }
                        let other = other.as_str().unwrap();
                        let theirs = self.devices[other].engine.safety_number(CHANNEL, &[]);
                        match relation.as_str() {
                            "same-as" => {
                                assert!(mine.is_some(), "{at}: no safety number");
                                assert_eq!(mine, theirs, "{at}: safety number vs {other}")
                            }
                            "differs-from" => {
                                assert_ne!(mine, theirs, "{at}: safety number vs {other}")
                            }
                            other => panic!("{at}: unknown safety number relation {other}"),
                        }
                    }
                    other => panic!("{at}: unknown expectation {other}"),
                }
            }
        }
    }

    fn describe_outbox(&self, device: &Device) -> Vec<String> {
        device
            .outbox
            .iter()
            .map(|(_, content)| match protocol::kind(content) {
                Kind::Handshake(handshake) => format!(
                    "handshake wantsReply={} accepted={:?}",
                    handshake.wants_reply,
                    handshake
                        .accepted_key_ids
                        .iter()
                        .map(|id| self.names.get(id).cloned().unwrap_or_else(|| "?".into()))
                        .collect::<Vec<_>>()
                ),
                Kind::Encrypted(_) => "message".to_owned(),
                _ => "other".to_owned(),
            })
            .collect()
    }

    fn check_outgoing(&self, at: &str, item: &Value, content: &str) {
        match (item, protocol::kind(content)) {
            (Value::String(kind), Kind::Encrypted(_)) if kind == "message" => {}
            (Value::String(kind), Kind::Handshake(_)) if kind == "handshake" => {}
            (Value::Object(object), Kind::Handshake(handshake))
                if object.contains_key("handshake") =>
            {
                let fields = &object["handshake"];
                if let Some(wants_reply) = fields.get("wantsReply") {
                    assert_eq!(
                        handshake.wants_reply,
                        wants_reply.as_bool().unwrap(),
                        "{at}: outbox wantsReply"
                    );
                }
                if let Some(accepted) = fields.get("acceptedKeys") {
                    let mut names: Vec<String> = handshake
                        .accepted_key_ids
                        .iter()
                        .map(|id| self.names.get(id).cloned().unwrap_or_else(|| "?".into()))
                        .collect();
                    names.sort();
                    let mut wanted: Vec<String> = accepted
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|n| n.as_str().unwrap().to_owned())
                        .collect();
                    wanted.sort();
                    assert_eq!(names, wanted, "{at}: outbox acceptedKeys");
                }
            }
            (item, _) => panic!("{at}: outbox item {item} doesn't match {}", content.len()),
        }
    }
}

fn trust_name(trust: Trust) -> &'static str {
    match trust {
        Trust::Accepted => "accepted",
        Trust::Pending => "pending",
        Trust::Rejected => "rejected",
    }
}

fn scenario_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../spec/scenarios")
}

fn run(path: &Path) {
    let text =
        fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let scenario: Value =
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let name = scenario["name"].as_str().expect("name");
    let mut sim = Sim::new(name, scenario["devices"].as_object().expect("devices"));
    for (index, step) in scenario["steps"]
        .as_array()
        .expect("steps")
        .iter()
        .enumerate()
    {
        if let Some(expect) = step.get("expect") {
            sim.check(index, expect.as_object().expect("expect object"));
        } else {
            sim.act(step);
            sim.sync();
        }
    }
}

#[test]
fn every_required_scenario_exists() {
    for name in REQUIRED {
        let path = scenario_dir().join(format!("{name}.json"));
        assert!(path.is_file(), "missing scenario {}", path.display());
    }
}

#[test]
fn all_scenarios_pass() {
    let mut paths: Vec<_> = fs::read_dir(scenario_dir())
        .expect("spec/scenarios")
        .map(|entry| entry.expect("entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no scenarios found");
    let only = std::env::var("SCENARIO").ok();
    for path in paths {
        if only
            .as_deref()
            .is_some_and(|only| !path.to_string_lossy().contains(only))
        {
            continue;
        }
        run(&path);
    }
}
