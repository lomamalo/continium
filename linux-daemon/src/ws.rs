use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio_tungstenite::tungstenite::Message;

use crate::continuity::{SharedBoxStatus, Store};

type Clients = Arc<Mutex<Vec<UnboundedSender<String>>>>;

/// Runs the WebSocket server: accepts client connections and relays every
/// line received from the ESP32 (via `esp_rx`) to all connected clients.
/// Commands received from any client are forwarded to `cmd_tx` (-> ESP32),
/// except `continuity_*` JSON messages which are handled locally (the store
/// lives here, not on the ESP32). Continuity events produced by the Linux
/// GUI's HTTP endpoint (via `cont_rx`) are broadcast to all clients too.
pub async fn run(
    ws_port: u16,
    mut esp_rx: UnboundedReceiver<String>,
    mut cont_rx: UnboundedReceiver<String>,
    cont_tx: UnboundedSender<String>,
    cmd_tx: UnboundedSender<String>,
    store: Arc<Store>,
    box_status: SharedBoxStatus,
) -> anyhow::Result<()> {
    let addr = SocketAddr::from(([0, 0, 0, 0], ws_port));
    let listener = TcpListener::bind(addr).await?;
    eprintln!("[ws] listening on {addr}");

    let clients: Clients = Arc::new(Mutex::new(Vec::new()));

    loop {
        tokio::select! {
            maybe_line = esp_rx.recv() => {
                match maybe_line {
                    Some(line) => broadcast(&clients, line),
                    None => {
                        eprintln!("[ws] esp_rx closed, shutting down ws server");
                        break;
                    }
                }
            }
            maybe_cont = cont_rx.recv() => {
                match maybe_cont {
                    Some(line) => broadcast(&clients, line),
                    None => {
                        eprintln!("[ws] cont_rx closed, shutting down ws server");
                        break;
                    }
                }
            }
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, peer)) => {
                        let clients = clients.clone();
                        let cmd_tx = cmd_tx.clone();
                        let cont_tx = cont_tx.clone();
                        let store = store.clone();
                        let box_status = box_status.clone();
                        tokio::spawn(async move {
                            if let Err(e) =
                                handle_client(stream, peer, clients, cmd_tx, cont_tx, store, box_status).await
                            {
                                eprintln!("[ws] client {peer} error: {e:#}");
                            }
                        });
                    }
                    Err(e) => eprintln!("[ws] accept error: {e}"),
                }
            }
        }
    }

    Ok(())
}

fn broadcast(clients: &Clients, line: String) {
    // NOTE: lock is held for the whole broadcast loop; see "Points faibles"
    // in ARCHITECTURE.md (potential contention with many clients).
    let mut guard = clients.lock().unwrap();
    guard.retain(|sender| sender.send(line.clone()).is_ok());
}

async fn handle_client(
    stream: TcpStream,
    peer: SocketAddr,
    clients: Clients,
    cmd_tx: UnboundedSender<String>,
    cont_tx: UnboundedSender<String>,
    store: Arc<Store>,
    box_status: SharedBoxStatus,
) -> anyhow::Result<()> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    eprintln!("[ws] client connected: {peer}");

    let (mut ws_sink, mut ws_stream) = ws_stream.split();
    let (client_tx, mut client_rx) = mpsc::unbounded_channel::<String>();
    let recv_tx = client_tx.clone();

    clients.lock().unwrap().push(client_tx);

    let send_task = async {
        while let Some(msg) = client_rx.recv().await {
            if ws_sink.send(Message::Text(msg)).await.is_err() {
                break;
            }
        }
    };

    let recv_task = async {
        while let Some(msg) = ws_stream.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    let handled = handle_continuity_message(&text, &recv_tx, &store, &cont_tx).await;
                    let handled = handled || handle_box_status_message(&text, &recv_tx, &box_status);
                    if !handled {
                        let _ = cmd_tx.send(text);
                    }
                }
                Ok(Message::Binary(bytes)) => {
                    // Binary messages are converted lossily to UTF-8; see
                    // "Points faibles" in ARCHITECTURE.md.
                    let text = String::from_utf8_lossy(&bytes).to_string();
                    let handled = handle_continuity_message(&text, &recv_tx, &store, &cont_tx).await;
                    let handled = handled || handle_box_status_message(&text, &recv_tx, &box_status);
                    if !handled {
                        let _ = cmd_tx.send(text);
                    }
                }
                Ok(Message::Close(_)) => break,
                Ok(_) => {}
                Err(_) => break,
            }
        }
    };

    tokio::select! {
        _ = send_task => {}
        _ = recv_task => {}
    }

    eprintln!("[ws] client disconnected: {peer}");
    // No heartbeat/ping is implemented; dead clients are only pruned lazily
    // on the next broadcast() call via `retain`.
    Ok(())
}

/// Handles a `{"type":"box_status"}` request locally: answers with the last
/// status reported by the box (or an explicit "unavailable"). Returns true
/// if handled (no forwarding to the ESP32).
fn handle_box_status_message(
    text: &str,
    client_tx: &UnboundedSender<String>,
    box_status: &SharedBoxStatus,
) -> bool {
    let v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return false,
    };
    if v.get("type").and_then(|t| t.as_str()) != Some("box_status") {
        return false;
    }
    let payload = match box_status.lock().unwrap().as_ref() {
        Some(status) => serde_json::to_string(status).unwrap_or_default(),
        None => "{}".to_string(),
    };
    let _ = client_tx.send(format!("{{\"type\":\"box_status\",\"status\":{payload}}}"));
    true
}

/// Handles continuity_* JSON messages locally. Returns true if the message
/// was a continuity message (already answered), false otherwise (it should
/// be forwarded to the ESP32).
async fn handle_continuity_message(
    text: &str,
    client_tx: &UnboundedSender<String>,
    store: &Arc<Store>,
    broadcast_tx: &UnboundedSender<String>,
) -> bool {
    let v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let msg_type = match v.get("type").and_then(|t| t.as_str()) {
        Some(t) if t.starts_with("continuity") => t,
        _ => return false,
    };

    match msg_type {
        "continuity_list" => {
            let items = store.list();
            let payload = serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string());
            let _ = client_tx.send(format!("{{\"type\":\"continuity_list\",\"items\":{payload}}}"));
        }
        "continuity_add" => {
            let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
            let source = v.get("source").and_then(|s| s.as_str()).unwrap_or("app").to_string();
            if !content.trim().is_empty() {
                store.add(&content, &source, &v);
                let _ = client_tx.send(format!(
                    "{{\"type\":\"continuity_list\",\"items\":{}}}",
                    serde_json::to_string(&store.list()).unwrap_or_else(|_| "[]".to_string())
                ));
            }
        }
        "continuity_del" => {
            if let Some(id) = v.get("id").and_then(|i| i.as_str()) {
                store.remove(id);
                let _ = client_tx.send(format!("{{\"type\":\"continuity_removed\",\"id\":\"{id}\"}}"));
            }
        }
        "continuity_back" => {
            let id = v.get("id").and_then(|c| c.as_str()).unwrap_or("").to_string();
            let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
            match store.back(&id, &content) {
                Ok(r) => {
                    let msg = format!(
                        "{{\"type\":\"file_backed\",\"id\":{},\"path\":{},\"wrote\":{}}}",
                        serde_json::to_string(&id).unwrap_or_default(),
                        serde_json::to_string(&r.path).unwrap_or_default(),
                        r.wrote
                    );
                    let _ = client_tx.send(msg.clone());
                    let _ = broadcast_tx.send(msg);
                }
                Err(e) => {
                    let msg = format!(
                        "{{\"type\":\"file_backed\",\"id\":{},\"ok\":false,\"error\":{}}}",
                        serde_json::to_string(&id).unwrap_or_default(),
                        serde_json::to_string(&e).unwrap_or_default()
                    );
                    let _ = client_tx.send(msg.clone());
                    let _ = broadcast_tx.send(msg);
                }
            }
        }
        _ => {}
    }
    true
}
