use std::fs;
use std::path::PathBuf;
use std::net::SocketAddr;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedSender;

/// A single continuity item: something captured on the PC (clipboard text,
/// a YouTube video, a file in the editor, ...) that can be finished on the
/// phone -- or, for files, edited on the phone and written back to the PC.
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct ContinuityItem {
    pub id: String,
    /// Top-level compartment: "presse-papier" | "video" | "fichier"
    pub category: String,
    /// Sub-type inside the category: "texte" | "lien" | "youtube" |
    /// "markdown" | "code" | ...
    #[serde(default)]
    pub kind: String,
    /// Human-readable title shown in the app.
    #[serde(default)]
    pub title: String,
    /// Payload: the text/link/file content.
    pub content: String,
    /// Extra data: {"video_id","position_s","duration_s","path","mime",...}
    #[serde(default)]
    pub meta: serde_json::Value,
    /// "clipboard" | "manual" | "app" | "extension" | "hotkey"
    pub source: String,
    pub created_at_ms: u64,
}

/// Thread-safe item store, persisted as JSON on disk so items survive a
/// daemon restart.
pub struct Store {
    inner: Arc<Mutex<Vec<ContinuityItem>>>,
    path: PathBuf,
}

const MAX_ITEMS: usize = 500;
// Same content re-raised = re-copy intent, not a duplicate. 60s covers the
// accidental double-capture (watcher + extension), while a copy made later
// is a deliberate new entry. Videos are deduplicated by video_id instead
// (position updates), so they are unaffected by this window.
const DEDUP_WINDOW_MS: u64 = 60_000;

impl Store {
    pub fn load() -> Self {
        let path = config_dir().join("continuity.json");
        let items = fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Vec<ContinuityItem>>(&raw).ok())
            .unwrap_or_default()
            .into_iter()
            .map(normalize_item)
            .collect();
        let store = Store {
            inner: Arc::new(Mutex::new(items)),
            path,
        };
        eprintln!("[continuity] loaded {} item(s) from {}", store.list().len(), store.path.display());
        store
    }

    pub fn list(&self) -> Vec<ContinuityItem> {
        let guard = self.inner.lock().unwrap();
        let mut items = guard.clone();
        items.sort_by(|a, b| b.created_at_ms.cmp(&a.created_at_ms));
        items
    }

    /// Classify, deduplicate and store. `hints` may carry rich data from the
    /// browser extension / hotkey: {"category","kind","title","meta":{...}}.
    pub fn add(&self, content: &str, source: &str, hints: &serde_json::Value) -> ContinuityItem {
        let cls = classify(content, hints);
        let now_ms = now_ms();

        let mut guard = self.inner.lock().unwrap();

        // Dedup: one item per video, position updated in place.
        if cls.category == "video" {
            let vid = cls.meta.get("video_id").and_then(|v| v.as_str());
            if let Some(vid) = vid {
                if let Some(existing) = guard.iter_mut().find(|i| {
                    i.category == "video"
                        && i.meta.get("video_id").and_then(|v| v.as_str()) == Some(vid)
                }) {
                    existing.created_at_ms = now_ms;
                    existing.title = cls.title.clone();
                    existing.content = content.trim().to_string();
                    if let Some(p) = cls.meta.get("position_s") {
                        existing.meta["position_s"] = p.clone();
                    }
                    if let Some(d) = cls.meta.get("duration_s") {
                        existing.meta["duration_s"] = d.clone();
                    }
                    if let Some(u) = cls.meta.get("url") {
                        existing.meta["url"] = u.clone();
                    }
                    existing.meta["updated_ms"] = json!(now_ms);
                    let item = existing.clone();
                    drop(guard);
                    self.save();
                    return item;
                }
            }
        }

        // Dedup: identical content re-raised (watchers on both sides, re-copies).
        if let Some(existing) = guard.iter_mut().find(|i| {
            i.content == content.trim() && i.category == cls.category && i.created_at_ms + DEDUP_WINDOW_MS > now_ms
        }) {
            existing.created_at_ms = now_ms;
            let item = existing.clone();
            drop(guard);
            self.save();
            return item;
        }

        let item = ContinuityItem {
            id: gen_id(),
            category: cls.category,
            kind: cls.kind,
            title: cls.title,
            content: content.trim().to_string(),
            meta: cls.meta,
            source: source.to_string(),
            created_at_ms: now_ms,
        };
        guard.push(item.clone());
        while guard.len() > MAX_ITEMS {
            guard.remove(0);
        }
        drop(guard);
        self.save();
        item
    }

    /// Phone -> PC: write the edited content back to the file this item was
    /// pushed from. If the item has no writable path (e.g. pushed from the
    /// browser), the edited content is kept on the item (pending_back) for a
    /// PC client to pick up.
    pub fn back(&self, id: &str, content: &str) -> Result<BackResult, String> {
        let mut guard = self.inner.lock().unwrap();
        let item = guard
            .iter_mut()
            .find(|i| i.id == id)
            .ok_or_else(|| "item not found".to_string())?;

        let path = item
            .meta
            .get("path")
            .and_then(|p| p.as_str())
            .map(str::to_string)
            .filter(|p| p.starts_with('/'));

        let mut wrote = false;
        if let Some(p) = &path {
            if std::path::Path::new(p).is_file() {
                fs::write(p, content).map_err(|e| format!("write failed: {e}"))?;
                wrote = true;
            } else {
                return Err(format!("path is not a file: {p}"));
            }
        }

        let now = now_ms();
        item.meta["edited_content"] = json!(content);
        item.meta["edited_at_ms"] = json!(now);
        item.meta["synced_back"] = json!(true);
        drop(guard);
        self.save();
        Ok(BackResult { path, wrote })
    }

    pub fn remove(&self, id: &str) -> bool {
        let mut guard = self.inner.lock().unwrap();
        let before = guard.len();
        guard.retain(|i| i.id != id);
        let removed = guard.len() != before;
        drop(guard);
        if removed {
            self.save();
        }
        removed
    }

    fn save(&self) {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir).ok();
        }
        if let Ok(raw) = serde_json::to_string_pretty(&self.list()) {
            fs::write(&self.path, raw).ok();
        }
    }
}

pub struct BackResult {
    pub path: Option<String>,
    pub wrote: bool,
}

/// Last known state of the battery-powered box (reported over WiFi by the
/// ESP32 after each sync), kept in memory so a phone that connects between
/// two syncs still sees the box's health.
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct BoxStatus {
    pub battery_mv: u32,
    pub stored: usize,
    pub last_sync_ms: u64,
    pub firmware: String,
}

pub type SharedBoxStatus = Arc<Mutex<Option<BoxStatus>>>;

pub fn shared_box_status() -> SharedBoxStatus {
    Arc::new(Mutex::new(None))
}

fn config_dir() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::var("HOME").map(PathBuf::from).unwrap_or_default().join(".config"));
    base.join("passerelle")
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

fn gen_id() -> String {
    format!("{:x}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos())
}

/* ---------------- Classification ---------------- */

pub struct Classified {
    pub category: String,
    pub kind: String,
    pub title: String,
    pub meta: serde_json::Value,
}

/// The daemon's "intelligence": decide the compartment (category/kind),
/// build a display title and enrich the metadata. `hints` come from the
/// browser extension / hotkey and take priority; clipboard content is
/// analyzed on its own.
pub fn classify(content: &str, hints: &serde_json::Value) -> Classified {
    let hcat = hints.get("category").and_then(|c| c.as_str());
    let hkind = hints.get("kind").and_then(|c| c.as_str());
    let htitle = hints.get("title").and_then(|c| c.as_str());
    let mut meta = hints.get("meta").cloned().unwrap_or(json!({}));
    let c = content.trim();

    // 1) File pushed from the PC (hotkey / GUI button).
    if hcat == Some("fichier") {
        let path: String = meta.get("path").and_then(|p| p.as_str()).unwrap_or("").to_string();
        let (kind, mime) = match hkind {
            Some(k) => (k.to_string(), mime_from_kind(k)),
            None => kind_for_path(&path),
        };
        if meta.get("mime").is_none() && !mime.is_empty() {
            meta["mime"] = json!(mime);
        }
        let title = htitle
            .map(str::to_string)
            .unwrap_or_else(|| path.rsplit('/').next().filter(|s| !s.is_empty()).unwrap_or("Fichier").to_string());
        return Classified {
            category: "fichier".to_string(),
            kind,
            title,
            meta,
        };
    }

    // 2) YouTube link (clipboard or extension).
    if let Some((vid, pos)) = parse_youtube(c) {
        if meta.get("video_id").is_none() {
            meta["video_id"] = json!(vid.clone());
        }
        if pos > 0 && meta.get("position_s").is_none() {
            meta["position_s"] = json!(pos);
        }
        if meta.get("url").is_none() {
            meta["url"] = json!(c);
        }
        let title = htitle
            .map(str::to_string)
            .unwrap_or_else(|| format!("Vidéo YouTube ({})", &vid[..vid.len().min(8)]));
        return Classified {
            category: "video".to_string(),
            kind: hkind.unwrap_or("youtube").to_string(),
            title,
            meta,
        };
    }

    // 3) Any other URL.
    if c.starts_with("http://") || c.starts_with("https://") {
        let host = c
            .split("://")
            .nth(1)
            .and_then(|r| r.split('/').next())
            .unwrap_or("lien");
        let title = htitle.map(str::to_string).unwrap_or_else(|| host.to_string());
        return Classified {
            category: "presse-papier".to_string(),
            kind: hkind.unwrap_or("lien").to_string(),
            title,
            meta,
        };
    }

    // 4) Plain text.
    let mut title = c.lines().next().unwrap_or(c).trim().to_string();
    if title.chars().count() > 60 {
        title = title.chars().take(60).collect::<String>() + "…";
    }
    let title = htitle.map(str::to_string).unwrap_or(title);
    Classified {
        category: "presse-papier".to_string(),
        kind: hkind.unwrap_or("texte").to_string(),
        title,
        meta,
    }
}

/// Upgrade items saved by older versions (flat "video"/"link"/"text").
fn normalize_item(mut i: ContinuityItem) -> ContinuityItem {
    if i.kind.is_empty() {
        i.kind = match i.category.as_str() {
            "video" => "youtube".to_string(),
            "link" => "lien".to_string(),
            "fichier" => "texte".to_string(),
            _ => "texte".to_string(),
        };
        i.category = match i.category.as_str() {
            "video" => "video".to_string(),
            "fichier" => "fichier".to_string(),
            _ => "presse-papier".to_string(),
        };
        if i.category == "video" && i.meta.get("video_id").is_none() {
            if let Some((vid, pos)) = parse_youtube(&i.content) {
                i.meta["video_id"] = json!(vid);
                if pos > 0 {
                    i.meta["position_s"] = json!(pos);
                }
            }
        }
    }
    if i.title.is_empty() {
        i.title = classify(&i.content, &json!({"category": i.category, "meta": i.meta.clone()})).title;
    }
    i
}

/// Extract (video_id, position_seconds) from a YouTube URL, or None.
fn parse_youtube(url: &str) -> Option<(String, u64)> {
    let (base, query) = match url.split_once('?') {
        Some((b, q)) => (b, Some(q)),
        None => (url, None),
    };
    let params: Vec<&str> = query.map(|q| q.split('&').collect()).unwrap_or_default();
    let t = params.iter().find_map(|p| p.strip_prefix("t=")).and_then(parse_t_seconds);
    let id = if base.contains("youtu.be/") {
        base.split("youtu.be/").nth(1)?.split(['/', '?', '&']).next()?.to_string()
    } else if base.contains("/shorts/") {
        base.split("/shorts/").nth(1)?.split(['/', '?', '&']).next()?.to_string()
    } else if let Some(i) = base.find("v=") {
        base[i + 2..].split('&').next()?.to_string()
    } else {
        // v= lives in the query string (youtube.com/watch?v=ID&t=...)
        params.iter().find_map(|p| p.strip_prefix("v="))?.to_string()
    };
    if id.is_empty() {
        return None;
    }
    Some((id, t.unwrap_or(0)))
}

/// Parse a `t=` parameter: "42", "1h2m3s", "5m".
fn parse_t_seconds(t: &str) -> Option<u64> {
    if t.is_empty() {
        return None;
    }
    if t.chars().all(|c| c.is_ascii_digit()) {
        return t.parse().ok();
    }
    let mut total = 0u64;
    let mut num = 0u64;
    for ch in t.chars() {
        if let Some(d) = ch.to_digit(10) {
            num = num * 10 + d as u64;
        } else {
            match ch {
                'h' => total += num * 3600,
                'm' => total += num * 60,
                's' => total += num,
                _ => return None,
            }
            num = 0;
        }
    }
    Some(total + num)
}

fn kind_for_path(path: &str) -> (String, String) {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "md" | "markdown" => ("markdown".to_string(), "text/markdown".to_string()),
        "txt" | "text" | "log" => ("texte".to_string(), "text/plain".to_string()),
        "csv" => ("texte".to_string(), "text/csv".to_string()),
        "json" => ("code".to_string(), "application/json".to_string()),
        "html" | "htm" => ("code".to_string(), "text/html".to_string()),
        "rs" | "c" | "h" | "py" | "js" | "ts" | "go" | "java" | "cpp" | "sh" | "toml" | "yaml" | "yml" => {
            ("code".to_string(), "text/plain".to_string())
        }
        _ => ("texte".to_string(), "text/plain".to_string()),
    }
}

fn mime_from_kind(kind: &str) -> String {
    match kind {
        "markdown" => "text/markdown".to_string(),
        "code" => "text/plain".to_string(),
        _ => "text/plain".to_string(),
    }
}

/* ---------------- Clipboard watcher (daemon-side) ---------------- */

/// Polls both the Wayland and X11 clipboards and pushes new content into
/// the store. Hyprland sessions (and most Wayland compositors) keep the X11
/// selection empty when the copy happened in a Wayland client, and vice
/// versa, so BOTH selections are watched. Runs in a plain thread (blocking
/// `wl-paste`/`xsel` calls). The store's dedup keeps this safe if another
/// watcher is still active.
pub fn run_clipboard_watcher(store: Arc<Store>, cont_tx: UnboundedSender<String>) {
    std::thread::spawn(move || {
        eprintln!("[clipboard] watcher started (wayland + x11)");
        let mut last_wayland: Option<String> = None;
        let mut last_x11: Option<String> = None;
        loop {
            let wl = Command::new("wl-paste")
                .arg("--no-newline")
                .output()
                .ok()
                .filter(|o| o.status.success());
            if let Some(out) = wl {
                let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !text.is_empty() && last_wayland.as_deref() != Some(text.as_str()) {
                    last_wayland = Some(text.clone());
                    capture(&store, &cont_tx, text);
                }
            }

            let x11 = Command::new("xsel")
                .args(["--clipboard", "--output"])
                .output()
                .or_else(|_| Command::new("xclip").args(["-selection", "clipboard", "-o"]).output());
            if let Ok(out) = x11 {
                if out.status.success() {
                    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if !text.is_empty() && last_x11.as_deref() != Some(text.as_str()) {
                        last_x11 = Some(text.clone());
                        capture(&store, &cont_tx, text);
                    }
                }
            }

            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    });
}

fn capture(store: &Store, cont_tx: &UnboundedSender<String>, text: String) {
    let item = store.add(&text, "clipboard", &json!({}));
    let _ = cont_tx.send(format!(
        "{{\"type\":\"continuity_item\",\"item\":{}}}",
        serde_json::to_string(&item).unwrap_or_default()
    ));
    eprintln!("[clipboard] captured {} bytes", text.len());
}

/* ---------------- HTTP endpoint ---------------- */

/// Minimal HTTP/1.1 endpoint for the Linux GUI / browser extension / phone
/// app (std-lib clients, no extra dependency):
///   POST /continuity          add an item ({"content","source", hints...})
///   POST /continuity/back     phone -> PC file write-back ({id, content})
///   GET  /continuity          list items
///   POST /box/status          ESP32 status report
/// CORS is enabled so the browser extension can call directly.
pub async fn run_http(
    port: u16,
    store: Arc<Store>,
    cont_tx: UnboundedSender<String>,
    box_status: SharedBoxStatus,
) {
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[http] bind {addr:?} failed: {e}");
            return;
        }
    };
    eprintln!("[http] listening on {addr:?} (POST/GET /continuity, POST /continuity/back, POST /box/status)");

    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                let store = store.clone();
                let cont_tx = cont_tx.clone();
                let box_status = box_status.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_http(stream, peer, store, cont_tx, box_status).await {
                        eprintln!("[http] {peer}: {e:#}");
                    }
                });
            }
            Err(e) => eprintln!("[http] accept error: {e}"),
        }
    }
}

async fn handle_http(
    mut stream: TcpStream,
    peer: std::net::SocketAddr,
    store: Arc<Store>,
    cont_tx: UnboundedSender<String>,
    box_status: SharedBoxStatus,
) -> anyhow::Result<()> {
    // Read request head (until \r\n\r\n). The body may arrive in the same
    // packet as the head, so keep track of where the head ends.
    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    let head_end;
    loop {
        let n = stream.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
        if let Some(pos) = head.windows(4).position(|w| w == b"\r\n\r\n") {
            head_end = Some(pos + 4);
            break;
        }
        if head.len() > 16 * 1024 {
            return Ok(());
        }
    }
    let head_end = head_end.unwrap_or(0);
    let head_str = String::from_utf8_lossy(&head[..head_end]);
    let mut lines = head_str.split("\r\n");
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut content_length = 0usize;
    for line in lines {
        let lower = line.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("content-length:") {
            content_length = rest.trim().parse().unwrap_or(0);
        }
    }

    // CORS preflight (browser extension).
    if request_line.starts_with("OPTIONS") {
        let resp = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        stream.write_all(resp.as_bytes()).await?;
        stream.flush().await?;
        return Ok(());
    }

    // Read the remaining body bytes: some may already be in the head buffer.
    let mut body: Vec<u8> = head[head_end..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&buf[..n]);
    }

    let (status, payload) = if request_line.starts_with("POST /continuity/back") {
        let parsed: Result<serde_json::Value, _> = serde_json::from_slice(&body);
        match parsed {
            Ok(v) => {
                let id = v.get("id").and_then(|c| c.as_str()).unwrap_or("").to_string();
                let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
                match store.back(&id, &content) {
                    Ok(r) => {
                        let msg = format!(
                            "{{\"type\":\"file_backed\",\"id\":{},\"path\":{},\"wrote\":{},\"content\":{}}}",
                            serde_json::to_string(&id).unwrap_or_default(),
                            serde_json::to_string(&r.path).unwrap_or_default(),
                            r.wrote,
                            serde_json::to_string(&content).unwrap_or_default()
                        );
                        let _ = cont_tx.send(msg);
                        (
                            200,
                            format!(
                                "{{\"ok\":true,\"path\":{}}}",
                                serde_json::to_string(&r.path).unwrap_or_default()
                            ),
                        )
                    }
                    Err(e) => (400, format!("{{\"ok\":false,\"error\":{}}}", serde_json::to_string(&e).unwrap_or_default())),
                }
            }
            Err(e) => (400, format!("{{\"ok\":false,\"error\":\"invalid json: {e}\"}}")),
        }
    } else if request_line.starts_with("POST /continuity") {
        let parsed: Result<serde_json::Value, _> = serde_json::from_slice(&body);
        match parsed {
            Ok(v) => {
                let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("").to_string();
                let source = v.get("source").and_then(|s| s.as_str()).unwrap_or("manual").to_string();
                if content.trim().is_empty() {
                    (400, "{\"ok\":false,\"error\":\"empty content\"}".to_string())
                } else {
                    let item = store.add(&content, &source, &v);
                    let _ = cont_tx.send(format!(
                        "{{\"type\":\"continuity_item\",\"item\":{}}}",
                        serde_json::to_string(&item).unwrap_or_default()
                    ));
                    (200, format!("{{\"ok\":true,\"item\":{}}}", serde_json::to_string(&item).unwrap_or_default()))
                }
            }
            Err(e) => (400, format!("{{\"ok\":false,\"error\":\"invalid json: {e}\"}}")),
        }
    } else if request_line.starts_with("GET /continuity") {
        let items = store.list();
        let payload = format!(
            "{{\"type\":\"continuity\",\"items\":{}}}",
            serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
        );
        (200, payload)
    } else if request_line.starts_with("POST /box/status") {
        let parsed: Result<serde_json::Value, _> = serde_json::from_slice(&body);
        match parsed {
            Ok(v) => {
                let status = BoxStatus {
                    battery_mv: v.get("battery_mv").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
                    stored: v.get("stored").and_then(|x| x.as_u64()).unwrap_or(0) as usize,
                    last_sync_ms: v.get("last_sync_ms").and_then(|x| x.as_u64()).unwrap_or(0),
                    firmware: v.get("firmware").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                };
                *box_status.lock().unwrap() = Some(status.clone());
                let _ = cont_tx.send(format!(
                    "{{\"type\":\"box_status\",\"status\":{}}}",
                    serde_json::to_string(&status).unwrap_or_default()
                ));
                (200, "{\"ok\":true}".to_string())
            }
            Err(e) => (400, format!("{{\"ok\":false,\"error\":\"invalid json: {e}\"}}")),
        }
    } else {
        (404, "{\"ok\":false,\"error\":\"not found\"}".to_string())
    };

    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        _ => "Not Found",
    };
    let resp = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        payload.len(),
        payload
    );
    stream.write_all(resp.as_bytes()).await?;
    stream.flush().await?;
    let _ = peer;
    Ok(())
}
