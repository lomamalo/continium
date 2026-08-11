//! Web app embarquee : le daemon sert l'interface (presse-papier partage)
//! directement depuis le binaire, aucune dependance externe.

pub const INDEX_HTML: &str = include_str!("../../web/index.html");
pub const APP_JS: &str = include_str!("../../web/app.js");
pub const STYLE_CSS: &str = include_str!("../../web/style.css");
pub const ICON_PNG: &[u8] = include_bytes!("../../web/icon.png");

/// Resout un chemin HTTP vers un fichier embarque.
/// Retourne (content-type, octets) ou None si inconnu.
pub fn serve(path: &str) -> Option<(&'static str, &'static [u8])> {
    match path {
        "/" | "/index.html" => Some(("text/html; charset=utf-8", INDEX_HTML.as_bytes())),
        "/app.js" => Some(("application/javascript; charset=utf-8", APP_JS.as_bytes())),
        "/style.css" => Some(("text/css; charset=utf-8", STYLE_CSS.as_bytes())),
        "/icon.png" | "/favicon.ico" => Some(("image/png", ICON_PNG)),
        _ => None,
    }
}
