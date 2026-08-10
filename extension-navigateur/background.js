const DEFAULT_HOST = "http://192.168.1.180:8081";

// Firefox (MV2) : les API chrome.* sont en mode callback, pas promesse.
// Ce wrapper marche dans les deux navigateurs.
const storageGet = (key) =>
  new Promise((resolve) => {
    chrome.storage.sync.get(key, (res) => resolve(res || {}));
  });

console.log("[passerelle] background chargé");

async function daemonUrl() {
  const stored = await storageGet("daemonUrl");
  const url = (stored.daemonUrl || DEFAULT_HOST).trim().replace(/\/+$/, "");
  return url || DEFAULT_HOST;
}

// The fetch runs here (extension context) instead of the content script:
// a fetch from an https:// page to the http:// daemon would be blocked as
// mixed content by the browser.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  console.log("[passerelle] message reçu:", msg && msg.type);
  if (msg && msg.type === "send_page") {
    (async () => {
      try {
        const resp = await fetch((await daemonUrl()) + "/continuity", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(msg.payload),
        });
        const json = await resp.json().catch(() => ({}));
        if (!resp.ok) throw new Error(json.error || "HTTP " + resp.status);
        console.log("[passerelle] envoyé OK");
        sendResponse({ ok: true, item: json.item });
      } catch (e) {
        console.error("[passerelle] échec:", e);
        sendResponse({ ok: false, error: String(e) });
      }
    })();
    return true; // keep the channel open for the async response
  }
});
