use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::task;
use tokio::time::sleep;

const RECONNECT_DELAY: Duration = Duration::from_secs(3);
const READ_TIMEOUT: Duration = Duration::from_millis(200);

/// Infinite reconnect loop: keeps trying to (re)open the serial port every
/// `RECONNECT_DELAY` for as long as the daemon runs.
pub async fn run(
    port_name: String,
    baud: u32,
    esp_tx: UnboundedSender<String>,
    mut cmd_rx: UnboundedReceiver<String>,
) {
    loop {
        match connect(&port_name, baud, esp_tx.clone(), &mut cmd_rx).await {
            Ok(()) => {
                eprintln!("[serial] connection closed cleanly, reconnecting...");
            }
            Err(e) => {
                eprintln!("[serial] error: {e:#}, retrying in {RECONNECT_DELAY:?}");
            }
        }
        sleep(RECONNECT_DELAY).await;
    }
}

async fn connect(
    port_name: &str,
    baud: u32,
    esp_tx: UnboundedSender<String>,
    cmd_rx: &mut UnboundedReceiver<String>,
) -> anyhow::Result<()> {
    let port = serialport::new(port_name, baud)
        .timeout(READ_TIMEOUT)
        .open()?;

    eprintln!("[serial] connected to {port_name} @ {baud}");

    let reader_port = port.try_clone()?;
    let mut writer_port = port;

    let done = Arc::new(AtomicBool::new(false));
    let reader_done = done.clone();

    // Blocking reader thread: BufReader::read_line() loop, forwards each
    // line to esp_tx. Uses the 200ms read timeout + `done` flag to be able
    // to stop when the outer loop wants to shut down / reconnect.
    let read_handle = task::spawn_blocking(move || {
        let mut reader = BufReader::new(reader_port);
        let mut line = String::new();
        loop {
            if reader_done.load(Ordering::Relaxed) {
                break;
            }
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break, // EOF: device gone
                Ok(_) => {
                    let trimmed = line.trim_end();
                    if !trimmed.is_empty() {
                        if esp_tx.send(trimmed.to_string()).is_err() {
                            break; // no one listening anymore
                        }
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    continue; // just a read timeout, check `done` and retry
                }
                Err(_) => break, // real IO error: device probably disconnected
            }
        }
    });

    // Async loop: forward commands from WS clients to the ESP32 over serial.
    // Polls read_handle.is_finished() to notice the reader thread died.
    loop {
        if read_handle.is_finished() {
            done.store(true, Ordering::Relaxed);
            break;
        }

        tokio::select! {
            maybe_cmd = cmd_rx.recv() => {
                match maybe_cmd {
                    Some(cmd) => {
                        let line = format!("{cmd}\n");
                        if let Err(e) = writer_port.write_all(line.as_bytes()) {
                            eprintln!("[serial] write error: {e}");
                            done.store(true, Ordering::Relaxed);
                            break;
                        }
                    }
                    None => {
                        // cmd_rx closed: daemon shutting down
                        done.store(true, Ordering::Relaxed);
                        break;
                    }
                }
            }
            _ = sleep(Duration::from_millis(100)) => {
                // Polling tick to re-check read_handle.is_finished(); see
                // "Points faibles" in ARCHITECTURE.md.
            }
        }
    }

    let _ = read_handle.await;
    Ok(())
}
