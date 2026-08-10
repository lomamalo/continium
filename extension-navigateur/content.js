(() => {
  const DAEMON = "http://192.168.1.180:8081";

  function youTubeInfo() {
    if (!/youtube\.com|youtu\.be/.test(location.hostname)) return null;
    const video = document.querySelector("video");
    if (!video) return null;
    const u = new URL(location.href);
    let videoId = u.searchParams.get("v");
    if (!videoId && u.pathname.startsWith("/shorts/")) videoId = u.pathname.split("/")[2] || null;
    if (!videoId && u.hostname === "youtu.be") videoId = u.pathname.split("/")[1] || null;
    if (!videoId) return null;
    return {
      video_id: videoId,
      position_s: Math.floor(video.currentTime),
      duration_s: Math.floor(video.duration || 0),
    };
  }

  function buildPayload() {
    const payload = {
      content: location.href,
      source: "extension",
      title: document.title || location.hostname,
    };
    const yt = youTubeInfo();
    if (yt) {
      payload.category = "video";
      payload.kind = "youtube";
      payload.meta = yt;
    }
    return payload;
  }

  // Route through the background event page (avoids mixed-content blocking
  // on https pages), with a hard timeout so the click never hangs.
  async function viaBackground(payload) {
    return new Promise((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (!done) {
          done = true;
          console.error("[passerelle] background ne répond pas");
          resolve(null);
        }
      }, 4000);
      try {
        chrome.runtime.sendMessage({ type: "send_page", payload }, (resp) => {
          if (!done) {
            done = true;
            clearTimeout(timer);
            resolve(resp || null);
          }
        });
      } catch (e) {
        if (!done) {
          done = true;
          clearTimeout(timer);
          console.error("[passerelle] sendMessage:", e);
          resolve(null);
        }
      }
    });
  }

  // Firefox (MV2) : chrome.* est en mode callback, pas promesse.
  const storageGet = (key) =>
    new Promise((resolve) => {
      chrome.storage.sync.get(key, (res) => resolve(res || {}));
    });

  // Direct fetch: works on http pages and as a fallback; blocked on https
  // pages (mixed content) but gives a clear error.
  async function directPost(payload) {
    const stored = await storageGet("daemonUrl");
    const host = (stored.daemonUrl || DAEMON).trim().replace(/\/+$/, "") || DAEMON;
    const resp = await fetch(host + "/continuity", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const json = await resp.json().catch(() => ({}));
    if (!resp.ok) throw new Error(json.error || "HTTP " + resp.status);
    return json;
  }

  async function sendPage() {
    const payload = buildPayload();
    const viaBg = await viaBackground(payload);
    if (viaBg && viaBg.ok) return viaBg;
    if (viaBg) throw new Error(viaBg.error || "envoi refusé par l'extension");
    console.warn("[passerelle] repli sur fetch direct");
    return directPost(payload);
  }

  let toast = null;
  function showToast(text, ok) {
    if (!toast) {
      toast = document.createElement("div");
      toast.style.cssText =
        "position:fixed;right:20px;bottom:20px;z-index:2147483647;background:#111;color:#fff;" +
        "padding:10px 16px;border-radius:8px;font:13px sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.4);" +
        "transition:opacity .3s;max-width:300px;word-break:break-word";
      document.documentElement.appendChild(toast);
    }
    toast.textContent = text;
    toast.style.background = ok ? "#1a7f37" : "#b3261e";
    toast.style.opacity = "1";
    clearTimeout(toast._t);
    toast._t = setTimeout(() => (toast.style.opacity = "0"), 2500);
  }

  function addButton() {
    // Guard against double injection (two extension instances / two content
    // scripts would stack two buttons and the top one can block the other).
    if (document.getElementById("passerelle-send-btn")) return;
    const btn = document.createElement("button");
    btn.id = "passerelle-send-btn";
    const reset = () => {
      btn.disabled = false;
      btn.textContent = "Envoyer au téléphone";
    };
    btn.textContent = "Envoyer au téléphone";
    btn.style.cssText =
      "position:fixed;right:20px;bottom:20px;z-index:2147483647;background:#1a7f37;color:#fff;" +
      "border:none;border-radius:20px;padding:10px 16px;font:600 13px sans-serif;cursor:pointer;" +
      "box-shadow:0 2px 10px rgba(0,0,0,.35)";
    btn.addEventListener("click", () => {
      // Immediate feedback: the button flips to "Envoyé ✓" for 3s and is
      // re-enabled no matter what, while the send runs in the background.
      btn.textContent = "Envoyé ✓";
      btn.disabled = true;
      setTimeout(reset, 3000);
      sendPage()
        .then((json) => {
          const label = json.item ? (json.item.title || "page") : "page";
          showToast("Envoyé : " + label, true);
        })
        .catch((e) => {
          console.error("[passerelle]", e);
          showToast("Échec (" + e.message + ") — daemon configuré ?", false);
        });
    });
    document.documentElement.appendChild(btn);
  }

  if (document.documentElement) {
    addButton();
  } else {
    document.addEventListener("DOMContentLoaded", addButton);
  }

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === "get_page_info") {
      sendResponse({
        title: document.title,
        url: location.href,
        position: youTubeInfo(),
      });
    }
  });
})();
