/* Continium — interactions du site (maquette) */

// Menu mobile (hamburger).
const navToggle = document.getElementById('navToggle');
const navLinks = document.getElementById('navLinks');
navToggle.addEventListener('click', () => {
  const open = navLinks.classList.toggle('open');
  navToggle.classList.toggle('open', open);
  navToggle.setAttribute('aria-expanded', String(open));
});
navLinks.addEventListener('click', (e) => {
  if (e.target.tagName === 'A') {
    navLinks.classList.remove('open');
    navToggle.classList.remove('open');
    navToggle.setAttribute('aria-expanded', 'false');
  }
});

// Copier la commande d'installation en un clic.
const oneLiner = 'curl -fsSL https://raw.githubusercontent.com/lomaloma/continium/main/continium-site/install-pc.sh | bash';
const copyBtn = document.getElementById('copyOneLiner');

async function copy(text, btn) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    // Fallback pour les navigateurs sans Clipboard API (http://, etc.)
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  if (!btn) return;
  btn.textContent = 'Copié ✓';
  btn.classList.add('copied');
  setTimeout(() => {
    btn.textContent = 'Copier';
    btn.classList.remove('copied');
  }, 2000);
}

copyBtn.addEventListener('click', () => copy(oneLiner, copyBtn));

// Bouton APK : lien direct vers la derniere release GitHub.
document.getElementById('apkBtn').addEventListener('click', () => {
  const btn = document.getElementById('apkBtn');
  btn.textContent = 'Téléchargement…';
  setTimeout(() => { btn.textContent = 'Télécharger l\'APK'; }, 3000);
});
