//! Test peer for the plugins' bridge client (`npm test`): starts a real bridge in the folder given
//! as the first argument, approves every pairing, and drives a connected plugin through a send
//! and a history request. Events are printed to stdout as JSON lines.

use duhcord_companion_bridge::{Bridge, BridgeConfig, BridgeEvent, CompanionFrame};
use duhcord_private_protocol::{self as protocol, ClientClass, Features, Handshake, Host};
use serde_json::json;

#[tokio::main]
async fn main() {
    let dir = std::env::args().nth(1).expect("config folder argument");
    let (bridge, mut events) = Bridge::start(&dir, BridgeConfig::default())
        .await
        .expect("bridge starts");
    println!(
        "{}",
        json!({"event": "listening", "port": bridge.local_addr().port()})
    );
    let handshake = protocol::handshake_content(&Handshake {
        key: protocol::PrivateKey::generate().public_key(),
        wants_reply: true,
        class: ClientClass::Companion,
        host: Host::BETTERDISCORD,
        features: Features::COMPANION_V1,
        accepted_key_ids: Vec::new(),
    });
    while let Some(event) = events.recv().await {
        let line = match event {
            BridgeEvent::PairingRequested {
                conn,
                code,
                host,
                user_id,
            } => {
                bridge.approve_pairing(conn).expect("approve");
                json!({"event": "pairing", "code": code, "host": host, "userId": user_id.to_string()})
            }
            BridgeEvent::Ready {
                conn,
                user_id,
                host,
            } => {
                json!({"event": "ready", "conn": conn, "userId": user_id.to_string(), "host": host})
            }
            BridgeEvent::Dm { conn, info } => {
                let channel = info.channel_id;
                bridge
                    .send(
                        conn,
                        CompanionFrame::Status {
                            channel_id: channel,
                            state: "waiting".to_owned(),
                            verified: false,
                            new_key: false,
                            peer_class: None,
                        },
                    )
                    .expect("status");
                bridge
                    .send(
                        conn,
                        CompanionFrame::Send {
                            nonce: "n1".to_owned(),
                            channel_id: channel,
                            content: handshake.clone(),
                        },
                    )
                    .expect("send");
                json!({"event": "dm", "channelId": channel.to_string(), "peer": info.peer.username})
            }
            BridgeEvent::Messages {
                conn,
                channel,
                messages,
                before,
                exhausted,
            } => {
                if before.is_none() {
                    bridge
                        .send(
                            conn,
                            CompanionFrame::NeedHistory {
                                channel_id: channel,
                                before: Some(999),
                            },
                        )
                        .expect("history");
                }
                json!({
                    "event": "messages",
                    "channelId": channel.to_string(),
                    "ids": messages.iter().map(|m| m.id.to_string()).collect::<Vec<_>>(),
                    "before": before.map(|id| id.to_string()),
                    "exhausted": exhausted,
                })
            }
            BridgeEvent::Sent {
                nonce, message_id, ..
            } => {
                json!({"event": "sent", "nonce": nonce, "messageId": message_id.to_string()})
            }
            BridgeEvent::SendFailed { nonce, error, .. } => {
                json!({"event": "sendFailed", "nonce": nonce, "error": error})
            }
            BridgeEvent::Open { channel, .. } => {
                json!({"event": "open", "channelId": channel.to_string()})
            }
            BridgeEvent::Deleted { ids, .. } => {
                json!({"event": "deleted", "ids": ids.iter().map(u64::to_string).collect::<Vec<_>>()})
            }
            BridgeEvent::Disconnected { .. } => json!({"event": "disconnected"}),
            BridgeEvent::VersionMismatch {
                plugin_outdated, ..
            } => {
                json!({"event": "versionMismatch", "pluginOutdated": plugin_outdated})
            }
        };
        println!("{line}");
    }
}
