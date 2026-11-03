#![forbid(unsafe_code)]
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
//! Tauri shell of the Duhcord Private Companion.
//!
//! All the work happens in [`duhcord_companion_service`]. This file adds the tray icon, the
//! windows (one main window, one per private chat), the commands the UI calls over Tauri IPC
//! (plaintext only ever moves over that in-process channel, never over loopback HTTP), and the
//! "Connect your Discord" helpers that copy the bundled plugins into each mod's folder.

use std::path::PathBuf;

use duhcord_companion_bridge::BridgeConfig;
use duhcord_companion_service::{
    AccountSummary, ChatDto, ChatSummary, OutdatedPlugin, OwnDeviceDto, PairingDto, PairingRequest,
    Service, UiEvent,
};
use duhcord_companion_store::Store;
use serde::Serialize;
use tauri::{
    ipc::Response,
    menu::{MenuBuilder, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, RunEvent, State, WebviewUrl, WebviewWindowBuilder, WindowEvent,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

const EVENT: &str = "companion";
const BD_PLUGIN: &str = "DuhcordPrivate.plugin.js";
const REPLUGGED_PLUGIN: &str = "dev.c4bra.DuhcordPrivate.asar";

struct AppState {
    service: Service,
}

type CommandResult<T> = Result<T, String>;

fn id(value: &str) -> CommandResult<u64> {
    value.parse().map_err(|_| "invalid id".to_owned())
}

fn err(error: impl std::fmt::Display) -> String {
    error.to_string()
}

// ---- commands ------------------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Overview {
    accounts: Vec<AccountSummary>,
    pairing_requests: Vec<PairingRequest>,
    pairings: Vec<PairingDto>,
    outdated_plugins: Vec<OutdatedPlugin>,
    locked: bool,
    bridge_port: u16,
    autostart: bool,
    version: &'static str,
}

#[tauri::command]
fn overview(app: AppHandle, state: State<'_, AppState>) -> CommandResult<Overview> {
    let service = &state.service;
    Ok(Overview {
        accounts: service.accounts(),
        pairing_requests: service.pending_pairings(),
        pairings: service.pairings().map_err(err)?,
        outdated_plugins: service.outdated_plugins(),
        locked: service.is_locked(),
        bridge_port: service.bridge_port(),
        autostart: app.autolaunch().is_enabled().unwrap_or(false),
        version: env!("CARGO_PKG_VERSION"),
    })
}

#[tauri::command]
fn chats(state: State<'_, AppState>, user_id: String) -> CommandResult<Vec<ChatSummary>> {
    state.service.chats(id(&user_id)?).map_err(err)
}

#[tauri::command]
fn chat(state: State<'_, AppState>, user_id: String, channel_id: String) -> CommandResult<ChatDto> {
    state
        .service
        .chat(id(&user_id)?, id(&channel_id)?)
        .map_err(err)
}

#[tauri::command]
fn send_text(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    text: String,
) -> CommandResult<()> {
    state
        .service
        .send_text(id(&user_id)?, id(&channel_id)?, &text)
        .map_err(err)
}

#[tauri::command]
fn set_private(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    enabled: bool,
) -> CommandResult<()> {
    state
        .service
        .set_private(id(&user_id)?, id(&channel_id)?, enabled)
        .map_err(err)
}

#[tauri::command]
fn resend_key(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
) -> CommandResult<()> {
    state
        .service
        .resend_key(id(&user_id)?, id(&channel_id)?)
        .map_err(err)
}

#[tauri::command]
fn set_companion_excluded(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    excluded: bool,
) -> CommandResult<()> {
    state
        .service
        .set_companion_excluded(id(&user_id)?, id(&channel_id)?, excluded)
        .map_err(err)
}

#[tauri::command]
fn safety_number(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    accepting: Vec<String>,
) -> CommandResult<Option<String>> {
    state
        .service
        .safety_number(id(&user_id)?, id(&channel_id)?, &accepting)
        .map_err(err)
}

#[tauri::command]
fn accept_keys(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    keys: Vec<String>,
    compared: Option<String>,
) -> CommandResult<()> {
    let compared = compared.map(|number| normalize_number(&number));
    state
        .service
        .accept_keys(id(&user_id)?, id(&channel_id)?, &keys, compared.as_deref())
        .map_err(err)
}

#[tauri::command]
fn reject_keys(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    keys: Vec<String>,
) -> CommandResult<()> {
    state
        .service
        .reject_keys(id(&user_id)?, id(&channel_id)?, &keys)
        .map_err(err)
}

#[tauri::command]
fn mark_verified(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
) -> CommandResult<()> {
    state
        .service
        .mark_verified(id(&user_id)?, id(&channel_id)?)
        .map_err(err)
}

#[tauri::command]
fn own_devices(state: State<'_, AppState>, user_id: String) -> CommandResult<Vec<OwnDeviceDto>> {
    state.service.own_devices(id(&user_id)?).map_err(err)
}

#[tauri::command]
fn set_own_device(
    state: State<'_, AppState>,
    user_id: String,
    key: String,
    accept: bool,
) -> CommandResult<()> {
    state
        .service
        .set_own_device(id(&user_id)?, &key, accept)
        .map_err(err)
}

#[tauri::command]
fn approve_pairing(state: State<'_, AppState>, conn: u64) -> CommandResult<()> {
    state.service.approve_pairing(conn).map_err(err)
}

#[tauri::command]
fn deny_pairing(state: State<'_, AppState>, conn: u64) -> CommandResult<()> {
    state.service.deny_pairing(conn).map_err(err)
}

#[tauri::command]
fn revoke_pairing(state: State<'_, AppState>, token_hash: String) -> CommandResult<bool> {
    state.service.revoke_pairing(&token_hash).map_err(err)
}

#[tauri::command]
fn set_locked(app: AppHandle, state: State<'_, AppState>, locked: bool) -> CommandResult<()> {
    if locked {
        state.service.lock_session();
        // Closing the chat windows drops whatever plaintext their webviews still hold.
        for (label, window) in app.webview_windows() {
            if label.starts_with("chat-") {
                let _ = window.destroy();
            }
        }
    } else {
        state.service.unlock_session();
    }
    Ok(())
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> CommandResult<()> {
    let launcher = app.autolaunch();
    if enabled {
        launcher.enable().map_err(err)
    } else {
        launcher.disable().map_err(err)
    }
}

/// Decrypted image bytes as a raw IPC response (never written to disk).
#[tauri::command]
async fn fetch_image(
    state: State<'_, AppState>,
    user_id: String,
    channel_id: String,
    message_id: String,
    attachment_id: String,
) -> CommandResult<Response> {
    let image = state
        .service
        .fetch_image(
            id(&user_id)?,
            id(&channel_id)?,
            id(&message_id)?,
            &attachment_id,
        )
        .await
        .map_err(err)?;
    Ok(Response::new(image.bytes.to_vec()))
}

#[tauri::command]
fn open_chat(app: AppHandle, user_id: String, channel_id: String) -> CommandResult<()> {
    open_chat_window(&app, &user_id, &channel_id).map_err(err)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Installed {
    path: String,
}

/// Copies a bundled plugin into a mod's plugins folder.
#[tauri::command]
fn install_plugin(app: AppHandle, host: String) -> CommandResult<Installed> {
    let (file, folder) = match host.as_str() {
        "betterdiscord" => (BD_PLUGIN, mod_folder("BetterDiscord")?),
        "replugged" => (REPLUGGED_PLUGIN, mod_folder("replugged")?),
        _ => return Err("this mod has no drop-in plugin folder".to_owned()),
    };
    let source = app
        .path()
        .resource_dir()
        .map_err(err)?
        .join("plugins")
        .join(file);
    if !source.is_file() {
        return Err(format!(
            "{file} isn't bundled with this build; download it from the GitHub release instead"
        ));
    }
    if !folder.parent().is_some_and(|parent| parent.is_dir()) {
        return Err(format!(
            "{} isn't installed for this user (no {} folder)",
            if host == "betterdiscord" {
                "BetterDiscord"
            } else {
                "Replugged"
            },
            folder
                .parent()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        ));
    }
    std::fs::create_dir_all(&folder).map_err(err)?;
    let target = folder.join(file);
    std::fs::copy(&source, &target).map_err(err)?;
    Ok(Installed {
        path: target.display().to_string(),
    })
}

fn mod_folder(name: &str) -> CommandResult<PathBuf> {
    directories::BaseDirs::new()
        .map(|dirs| dirs.config_dir().join(name).join("plugins"))
        .ok_or_else(|| "no config folder for this user".to_owned())
}

/// Safety numbers are 12 groups of 5 digits; accept whatever spacing the user typed.
fn normalize_number(number: &str) -> String {
    let digits: String = number.chars().filter(char::is_ascii_digit).collect();
    digits
        .as_bytes()
        .chunks(5)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

// ---- windows -------------------------------------------------------------------------------------

fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn open_chat_window(app: &AppHandle, user_id: &str, channel_id: &str) -> tauri::Result<()> {
    if user_id.parse::<u64>().is_err() || channel_id.parse::<u64>().is_err() {
        return Ok(());
    }
    let label = format!("chat-{user_id}-{channel_id}");
    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.unminimize();
        window.show()?;
        return window.set_focus();
    }
    let url = format!("index.html?view=chat&user={user_id}&channel={channel_id}");
    WebviewWindowBuilder::new(app, label, WebviewUrl::App(url.into()))
        .title("Private chat")
        .inner_size(460.0, 680.0)
        .min_inner_size(340.0, 420.0)
        .build()?;
    Ok(())
}

fn forward_events(app: AppHandle, mut events: tokio::sync::mpsc::UnboundedReceiver<UiEvent>) {
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            match &event {
                UiEvent::PairingRequested(_) => show_main(&app),
                UiEvent::OpenChat {
                    user_id,
                    channel_id,
                } => {
                    let _ = open_chat_window(&app, user_id, channel_id);
                }
                _ => {}
            }
            let _ = app.emit(EVENT, &event);
        }
    });
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Duhcord Companion", true, None::<&str>)?;
    let lock = MenuItem::with_id(app, "lock", "Lock", true, None::<&str>)?;
    let unlock = MenuItem::with_id(app, "unlock", "Unlock", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = MenuBuilder::new(app)
        .items(&[&open, &lock, &unlock])
        .separator()
        .item(&quit)
        .build()?;
    let mut tray = TrayIconBuilder::with_id("main")
        .tooltip("Duhcord Companion")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "lock" | "unlock" => {
                let locked = event.id().as_ref() == "lock";
                let state = app.state::<AppState>();
                let _ = set_locked(app.clone(), state, locked);
            }
            "quit" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    app.state::<AppState>().service.shutdown().await;
                    app.exit(0);
                });
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

fn main() {
    let start_hidden = std::env::args().any(|arg| arg == "--hidden");
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app)
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .setup(move |app| {
            let config_dir = Store::default_config_dir()?;
            let config = BridgeConfig {
                companion_version: env!("CARGO_PKG_VERSION").to_owned(),
            };
            let (service, events) =
                tauri::async_runtime::block_on(Service::start(&config_dir, config))?;
            app.manage(AppState { service });
            forward_events(app.handle().clone(), events);
            build_tray(app.handle())?;
            let first_run = !config_dir.join("first-run-done").exists();
            if first_run {
                // Start at login by default, as the plan says; the user can turn it off.
                let _ = app.autolaunch().enable();
                let _ = std::fs::write(config_dir.join("first-run-done"), b"");
            }
            if !start_hidden || first_run {
                show_main(app.handle());
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    // The companion keeps running in the tray so the bridge stays up.
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            overview,
            chats,
            chat,
            send_text,
            set_private,
            resend_key,
            set_companion_excluded,
            safety_number,
            accept_keys,
            reject_keys,
            mark_verified,
            own_devices,
            set_own_device,
            approve_pairing,
            deny_pairing,
            revoke_pairing,
            set_locked,
            set_autostart,
            fetch_image,
            open_chat,
            install_plugin,
        ])
        .build(tauri::generate_context!())
        .expect("failed to start Duhcord Companion");
    app.run(|_app, event| {
        if let RunEvent::ExitRequested {
            code: None, api, ..
        } = event
        {
            // Closing the last window doesn't quit; use the tray's Quit.
            api.prevent_exit();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::normalize_number;

    #[test]
    fn typed_safety_numbers_are_regrouped() {
        assert_eq!(
            normalize_number("12345-67890\n11111 22222"),
            "12345 67890 11111 22222"
        );
    }
}
