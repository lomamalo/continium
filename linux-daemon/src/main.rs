mod continuity;
mod discovery;
mod serial;
mod web;
mod ws;

use std::sync::Arc;

use clap::Parser;
use tokio::sync::mpsc;

/// Passerelle daemon: bridges the ESP32 (USB serial, JSON lines) to Android
/// clients (WebSocket, JSON relay). Also hosts a small HTTP endpoint
/// (POST /continuity) used by the Linux GUI's clipboard watcher, plus the
/// continuity item store shared by all clients.
#[derive(Parser, Debug, Clone)]
#[command(name = "passerelle-daemon", version)]
struct Args {
    /// Serial port connected to the ESP32 (USB Serial/JTAG)
    #[arg(long, default_value = "/dev/ttyACM0")]
    serial_port: String,

    /// Baud rate for the serial connection
    #[arg(long, default_value_t = 115200)]
    serial_baud: u32,

    /// TCP port the WebSocket server listens on
    #[arg(long, default_value_t = 8080)]
    ws_port: u16,

    /// TCP port the HTTP endpoint (POST /continuity) listens on
    #[arg(long, default_value_t = 8081)]
    http_port: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // ESP32 -> WS clients
    let (esp_tx, esp_rx) = mpsc::unbounded_channel::<String>();
    // WS clients -> ESP32
    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<String>();
    // Continuity events (HTTP endpoint / local handling) -> broadcast to WS clients
    let (cont_tx, cont_rx) = mpsc::unbounded_channel::<String>();

    eprintln!(
        "passerelle-daemon starting: serial={} @ {}, ws_port={}, http_port={}",
        args.serial_port, args.serial_baud, args.ws_port, args.http_port
    );

    let store = Arc::new(continuity::Store::load());
    let box_status = continuity::shared_box_status();

    // Clipboard watcher: pushes new clipboard content into the store and
    // broadcasts it, so the phone keeps working even with no GUI running.
    continuity::run_clipboard_watcher(store.clone(), cont_tx.clone());

    let serial_port = args.serial_port.clone();
    let serial_baud = args.serial_baud;
    tokio::spawn(async move {
        serial::run(serial_port, serial_baud, esp_tx, cmd_rx).await;
    });

    let http_store = store.clone();
    let http_cont_tx = cont_tx.clone();
    let http_box_status = box_status.clone();
    tokio::spawn(async move {
        continuity::run_http(args.http_port, http_store, http_cont_tx, http_box_status).await;
    });

    // UDP beacon: lets the phone / Linux apps find this daemon automatically.
    let disc_ws = args.ws_port;
    let disc_http = args.http_port;
    tokio::spawn(async move {
        if let Err(e) = discovery::run(disc_ws, disc_http).await {
            eprintln!("[discovery] error: {e:#}");
        }
    });

    ws::run(args.ws_port, esp_rx, cont_rx, cont_tx, cmd_tx, store, box_status).await?;

    Ok(())
}
