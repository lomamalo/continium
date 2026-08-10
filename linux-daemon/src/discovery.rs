//! Tiny UDP discovery beacon: apps broadcast "PASSERELLE_DISCOVER" on port
//! 8082 and the daemon answers with its ports, so no IP needs to be typed.

use tokio::net::UdpSocket;

const DISCOVERY_PORT: u16 = 8082;
const MAGIC: &[u8] = b"PASSERELLE_DISCOVER";

pub async fn run(ws_port: u16, http_port: u16) -> anyhow::Result<()> {
    let sock = UdpSocket::bind(("0.0.0.0", DISCOVERY_PORT)).await?;
    eprintln!("[discovery] listening on udp 0.0.0.0:{DISCOVERY_PORT}");
    let mut buf = [0u8; 1024];
    loop {
        let (n, from) = sock.recv_from(&mut buf).await?;
        if &buf[..n] == MAGIC {
            let reply = format!(
                "{{\"type\":\"discover\",\"name\":\"passerelle\",\"ws_port\":{ws_port},\"http_port\":{http_port}}}"
            );
            let _ = sock.send_to(reply.as_bytes(), from).await;
            eprintln!("[discovery] answered {from}");
        }
    }
}
