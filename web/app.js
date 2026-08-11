'use strict';

/* Continium — app web servie par le daemon (http://127.0.0.1:8081). */

const HOST = location.hostname || '127.0.0.1';
const WS_URL = `ws://${HOST}:8080`;

const itemsEl = document.getElementById('items');
const emptyEl = document.getElementById('empty');
const snackEl = document.getElementById('snack');
const connEl = document.getElementById('conn');
const connText = document.getElementById('connText');
const boxState = document.getElementById('boxState');
const boxExtra = document.getElementById('boxExtra');

let ws = null;
let boxSeen = 0;

function setConn(ok, text) {
  connText.textContent = text;
  connEl.classList.toggle('on', ok);
}

function snack(msg) {
  snackEl.textContent = msg;
  snackEl.hidden = false;
  clearTimeout(snack._t);
  snack._t = setTimeout(() => { snackEl.hidden = true; }, 2200);
}

function timeAgo(ms) {
  const s = Math.floor((Date.now() - ms) / 1000);
  if (s < 60) return "a l'instant";
  if (s < 3600) return `il y a ${Math.floor(s / 60)} min`;
  if (s < 86400) return `il y a ${Math.floor(s / 3600)} h`;
  return `il y a ${Math.floor(s / 86400)} j`;
}

function kindLabel(item) {
  const map = {
    texte: 'TEXTE', lien: 'LIEN', youtube: 'YOUTUBE',
    markdown: 'MARKDOWN', code: 'CODE', fichier: 'FICHIER',
  };
  return map[item.kind] || item.category.toUpperCase();
}

function isLink(item) {
  return item.category === 'presse-papier' && /^https?:\/\//i.test(item.content.trim());
}

function formatTime(s) {
  s = Math.max(0, Math.floor(Number(s) || 0));
  const m = Math.floor(s / 60);
  const sec = String(s % 60).padStart(2, '0');
  return `${m}:${sec}`;
}

function btn(label, kind, onClick) {
  const b = document.createElement('button');
  b.className = `btn ${kind}`;
  b.textContent = label;
  b.addEventListener('click', onClick);
  return b;
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (_) {
    // Fallback pour http:// hors contexte securise (LAN) et anciens navigateurs.
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
    ta.remove();
    return ok;
  }
}

function render(items) {
  itemsEl.innerHTML = '';
  emptyEl.hidden = items.length > 0;
  for (const item of items) {
    const card = document.createElement('article');
    card.className = 'card';

    const head = document.createElement('div');
    head.className = 'card-head';
    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.textContent = kindLabel(item);
    const title = document.createElement('h3');
    title.textContent = item.title || item.content.slice(0, 60);
    const time = document.createElement('time');
    time.textContent = timeAgo(item.created_at_ms);
    head.append(badge, title, time);

    const body = document.createElement('div');
    body.className = 'card-body';
    const content = document.createElement('p');
    let text = item.content;
    if (item.category === 'video') {
      const pos = item.meta && item.meta.position_s;
      const dur = item.meta && item.meta.duration_s;
      if (dur) text += ` (${formatTime(pos)} / ${formatTime(dur)})`;
    }
    content.textContent = text;
    body.appendChild(content);

    const actions = document.createElement('div');
    actions.className = 'actions';
    actions.appendChild(btn('Copier', '', async () => {
      const ok = await copyText(item.content);
      snack(ok ? 'Copie dans le presse-papier' : 'Copie impossible');
    }));
    if (isLink(item)) {
      actions.appendChild(btn('Ouvrir', '', () => window.open(item.content.trim(), '_blank')));
    }
    actions.appendChild(btn('Supprimer', 'del', () => {
      send({ type: 'continuity_del', id: item.id });
    }));

    card.append(head, body, actions);
    itemsEl.appendChild(card);
  }
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}
function refresh() { send({ type: 'continuity_list' }); }

function boxPercent(mv) {
  return Math.round(Math.min(100, Math.max(0, ((mv - 3200) / 1000) * 100)));
}

function handleBox(status) {
  boxSeen = Date.now();
  const mv = status.battery_mv;
  if (mv) {
    boxState.textContent = `Boitier : ${boxPercent(mv)} %`;
    boxExtra.textContent = status.charging ? 'en charge' : (status.state || '');
  } else {
    boxState.textContent = 'Boitier : connecte';
    boxExtra.textContent = status.firmware ? `fw ${status.firmware}` : '';
  }
}

function connect() {
  ws = new WebSocket(WS_URL);
  ws.onopen = () => { setConn(true, 'connecte'); refresh(); };
  ws.onclose = () => { setConn(false, 'reconnexion…'); setTimeout(connect, 3000); };
  ws.onerror = () => { try { ws.close(); } catch (_) {} };
  ws.onmessage = (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch (_) { return; }
    const t = msg.type;
    if (t === 'continuity_list') render(msg.items || []);
    else if (t === 'continuity_item' || t === 'continuity_removed') refresh();
    else if (t === 'box_status') handleBox(msg.status || {});
    else if (t === 'info' || t === 'alive' || t === 'boot') handleBox(msg);
  };
}

// Boitier injoignable apres 20 s sans nouvelle.
setInterval(() => {
  if (boxSeen && Date.now() - boxSeen > 20000) {
    boxState.textContent = 'Boitier : veille ou injoignable';
    boxExtra.textContent = '';
  }
}, 5000);

connect();
