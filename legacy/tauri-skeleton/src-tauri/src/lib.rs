#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod download;
mod recorder;
mod supervisor;

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::State;

/// Shared application state managed by Tauri.
pub struct AppState {
    pub supervisor: Mutex<Option<supervisor::Supervisor>>,
    pub recorder: Mutex<recorder::Recorder>,
    pub default_port: u16,
}

#[derive(Serialize, Clone)]
pub struct DshStatus {
    pub running: bool,
    pub ready: bool,
    pub port: u16,
    pub url: Option<String>,
}

/// Return the first TCP port at or after `start` that is free on 127.0.0.1.
fn find_free_port(start: u16) -> u16 {
    for port in start..(start + 100) {
        if std::net::TcpListener::bind(("127.0.0.1", port)).is_ok() {
            return port;
        }
    }
    start
}

#[tauri::command]
fn start_dsh(state: State<AppState>) -> Result<DshStatus, String> {
    let mut guard = state.supervisor.lock().unwrap();
    if let Some(sup) = guard.as_ref() {
        let ready = sup.is_ready();
        return Ok(DshStatus {
            running: true,
            ready,
            port: sup.port,
            url: Some(format!("http://127.0.0.1:{}", sup.port)),
        });
    }

    // Make sure a `dsh` binary is available (optionally build the pinned submodule).
    download::ensure_dsh_binary()?;

    let port = find_free_port(state.default_port);
    let sup = supervisor::Supervisor::start(port).map_err(|e| {
        format!(
            "启动 dsh 失败: {e}。请确认 dsh 已安装并在 PATH 中（或 submodule 已构建）。"
        )
    })?;

    let ready = sup.wait_for_ready(Duration::from_secs(30));
    let bound_port = sup.port;
    *guard = Some(sup);

    Ok(DshStatus {
        running: true,
        ready,
        port: bound_port,
        url: Some(format!("http://127.0.0.1:{}", bound_port)),
    })
}

#[tauri::command]
fn stop_dsh(state: State<AppState>) -> Result<(), String> {
    let mut guard = state.supervisor.lock().unwrap();
    if let Some(mut sup) = guard.take() {
        sup.stop();
    }
    Ok(())
}

#[tauri::command]
fn dsh_status(state: State<AppState>) -> DshStatus {
    let guard = state.supervisor.lock().unwrap();
    match guard.as_ref() {
        Some(sup) => {
            let ready = sup.is_ready();
            DshStatus {
                running: true,
                ready,
                port: sup.port,
                url: Some(format!("http://127.0.0.1:{}", sup.port)),
            }
        }
        None => DshStatus {
            running: false,
            ready: false,
            port: state.default_port,
            url: None,
        },
    }
}

#[tauri::command]
fn dsh_url(state: State<AppState>) -> Option<String> {
    let guard = state.supervisor.lock().unwrap();
    guard
        .as_ref()
        .map(|sup| format!("http://127.0.0.1:{}", sup.port))
}

/// Toggle session recording (stub — wire up scap/cpal/ffmpeg in recorder.rs).
#[tauri::command]
fn toggle_record(state: State<AppState>, path: String) -> Result<bool, String> {
    let mut rec = state.recorder.lock().unwrap();
    if rec.is_active() {
        rec.stop();
        Ok(false)
    } else {
        rec.start(&path);
        Ok(true)
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let default_port = std::env::var("DSH_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3080);

    let state = AppState {
        supervisor: Mutex::new(None),
        recorder: Mutex::new(recorder::Recorder::new()),
        default_port,
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(state)
        .setup(|app| {
            // System tray with a Quit action.
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&quit])?;
            let _tray = TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .on_menu_event(|app, event| {
                    if event.id.as_ref() == "quit" {
                        app.exit(0);
                    }
                })
                .build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            start_dsh,
            stop_dsh,
            dsh_status,
            dsh_url,
            toggle_record
        ])
        .run(tauri::generate_context!())
        .expect("error while running dsh-desktop");
}
