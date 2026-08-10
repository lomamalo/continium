const DEFAULT_HOST = "http://192.168.1.180:8081";

const el = {
  daemonUrl: document.getElementById("daemonUrl"),
  pageTitle: document.getElementById("pageTitle"),
  ytPos: document.getElementById("ytPos"),
  send: document.getElementById("send"),
  status: document.getElementById("status"),
};

// Firefox (MV2) : les API chrome.* sont en mode callback, pas promesse.
// Ces wrappers marchent dans les deux navigateurs.
const storageGet = (key) =>
  new Promise((resolve) => {
    chrome.storage.sync.get(key, (res) => resolve(res || {}));
  });
const storageSet = (obj) =>
  new Promise((resolve) => {
    chrome.storage.sync.set(obj, () => resolve());
  });
const tabsQuery = (q) =>
  new Promise((resolve) => {
    chrome.tabs.query(q, (tabs) => resolve(tabs || []));
  });
const tabsSend = (id, msg) =>
  new Promise((resolve) => {
    try {
      chrome.tabs.sendMessage(id, msg, (resp) => resolve(resp || {}));
    } catch (e) {
      resolve({});
    }
  });

function status(text, ok) {
  el.status.textContent = text;
  el.status.className = ok === undefined ? "" : ok ? "ok" : "err";
}

async function daemonUrl() {
  const stored = await storageGet("daemonUrl");
  const url = (stored.daemonUrl || DEFAULT_HOST).trim().replace(/\/+$/, "");
  return url || DEFAULT_HOST;
}

async function getTab() {
  const tabs = await tabsQuery({ active: true, currentWindow: true });
  return tabs[0];
}

async function getPageInfo(tab) {
  return tabsSend(tab.id, { type: "get_page_info" });
}

function fmtPosition(s) {
  if (s === null || s === undefined) return "—";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60);
  return (h ? h + "h" : "") + (h || m ? m + "m" : "") + sec + "s";
}

async function refresh() {
  el.daemonUrl.value = await daemonUrl();
  const tab = await getTab();
  if (!tab) return;
  el.pageTitle.textContent = tab.title || tab.url || "—";
  const info = await getPageInfo(tab);
  if (info && info.position) {
    el.ytPos.textContent =
      fmtPosition(info.position.position_s) +
      " / " + fmtPosition(info.position.duration_s);
  } else {
    el.ytPos.textContent = "—";
  }
  void tab;
}

async function send() {
  const tab = await getTab();
  if (!tab || !tab.url) {
    status("Pas d'onglet actif.", false);
    return;
  }
  if (!/^https?:/.test(tab.url)) {
    status("Page non envoyable (" + tab.url.slice(0, 20) + "…).", false);
    return;
  }
  const info = await getPageInfo(tab);
  const payload = {
    content: tab.url,
    source: "extension",
    title: tab.title || tab.url,
  };
  if (info && info.position) {
    payload.category = "video";
    payload.kind = "youtube";
    payload.meta = info.position;
  }
  el.send.disabled = true;
  status("Envoi…");
  try {
    const resp = await fetch((await daemonUrl()) + "/continuity", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const json = await resp.json().catch(() => ({}));
    if (!resp.ok) throw new Error(json.error || "HTTP " + resp.status);
    status("Envoyé : " + (json.item && json.item.title), true);
  } catch (e) {
    status("Échec : " + e.message, false);
  }
  el.send.disabled = false;
}

el.send.addEventListener("click", send);
el.daemonUrl.addEventListener("change", async () => {
  await storageSet({ daemonUrl: el.daemonUrl.value.trim() });
  status("Adresse enregistrée.", true);
});

refresh();
