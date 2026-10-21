// Reglages Osmocom - web/index.html, servi par tools/osmo-reglages.py (API /api/...)
'use strict';

const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function msg(t, ok = true) {
  const m = $('#msg');
  m.textContent = t;
  m.className = ok ? 'ok' : 'err';
  clearTimeout(msg.t);
  msg.t = setTimeout(() => (m.textContent = ''), 6000);
}

async function api(u, corps) {
  const r = await fetch(u, corps === undefined ? {} :
    { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corps) });
  const j = await r.json();
  if (!r.ok) throw new Error(j.err || r.status);
  return j;
}

/* ── onglets ── */
document.querySelectorAll('nav button').forEach(b => b.onclick = () => {
  document.querySelectorAll('nav button, .onglet').forEach(x => x.classList.remove('actif'));
  b.classList.add('actif');
  $('#' + b.dataset.o).classList.add('actif');
  try { localStorage.setItem('onglet', b.dataset.o); } catch (e) { }
  if (b.dataset.o === 'etat') chargerEtat();
});

/* ── formulaires globals.conf / instance ──
 * Un champ = {cle, val, section, doc, defaut, choix[]}. Vide = defaut du script (grise). Quand les scripts
 * comparent la variable a des valeurs fixes (choix), un menu deroulant : « (defaut) », les choix, et la
 * valeur actuelle si elle n'en fait pas partie. "autre…" rend la saisie libre. */
function dessinerForm(champs, conteneur, filtre, posees) {
  const f = filtre.trim().toLowerCase();
  const parSec = new Map();
  for (const c of champs) {
    if (f && !(c.cle + ' ' + c.doc + ' ' + c.section).toLowerCase().includes(f)) continue;
    if (posees && c.val === '') continue;
    if (!parSec.has(c.section)) parSec.set(c.section, []);
    parSec.get(c.section).push(c);
  }
  const champ = c => {
    const id = conteneur.id + '_' + c.cle;
    let ctrl;
    if (c.choix && c.choix.length) {
      const opts = ['<option value="">(défaut' + (c.defaut ? ' : ' + esc(c.defaut) : '') + ')</option>'];
      const vals = c.choix.slice();
      if (c.val !== '' && !vals.includes(c.val)) vals.unshift(c.val);
      for (const v of vals) opts.push(`<option value="${esc(v)}"${v === c.val ? ' selected' : ''}>${esc(v)}</option>`);
      opts.push('<option value="\u0000autre">autre…</option>');
      ctrl = `<select id="${id}" data-cle="${c.cle}" data-orig="${esc(c.val)}">${opts.join('')}</select>`;
    } else {
      ctrl = `<input id="${id}" data-cle="${c.cle}" data-orig="${esc(c.val)}" value="${esc(c.val)}" placeholder="${esc(c.defaut || '')}">`;
    }
    return `<div class="champ${c.val !== '' ? ' pose' : ''}"><label for="${id}">${c.cle}<small>${esc(c.doc)}</small></label>${ctrl}</div>`;
  };
  conteneur.innerHTML = [...parSec].map(([s, l]) =>
    `<div class="carte"><h2>${esc(s || 'Divers')} <small>(${l.length})</small></h2><div class="grille">${l.map(champ).join('')}</div></div>`
  ).join('') || '<p class="aide">Aucun réglage ne correspond.</p>';
  conteneur.querySelectorAll('input, select').forEach(x => {
    const maj = () => x.classList.toggle('modifie', x.value !== x.dataset.orig);
    x.oninput = maj;
    x.onchange = () => {
      if (x.tagName === 'SELECT' && x.value === '\u0000autre') {
        // bascule en saisie libre, meme id/cle
        const i = document.createElement('input');
        i.id = x.id; i.dataset.cle = x.dataset.cle; i.dataset.orig = x.dataset.orig; i.value = x.dataset.orig;
        i.oninput = () => i.classList.toggle('modifie', i.value !== i.dataset.orig);
        x.replaceWith(i); i.focus();
        return;
      }
      maj();
    };
  });
}
const modifies = conteneur => {
  const v = {};
  conteneur.querySelectorAll('input.modifie, select.modifie').forEach(x => (v[x.dataset.cle] = x.value));
  return v;
};

/* ── globals.conf ── */
let champs = [];
async function chargerGlobals() { champs = await api('/api/globals'); dessinerGlobals(); }
const dessinerGlobals = () => dessinerForm(champs, $('#g-form'), $('#g-filtre').value, $('#g-modifiees').checked);
$('#g-filtre').oninput = dessinerGlobals;
$('#g-modifiees').onchange = dessinerGlobals;
$('#g-enr').onclick = async () => {
  const v = modifies($('#g-form'));
  if (!Object.keys(v).length) return msg('Rien de modifié');
  try { await api('/api/globals', v); msg('globals.conf réécrit : ' + Object.keys(v).join(', ')); chargerGlobals(); }
  catch (e) { msg(e.message, false); }
};

/* ── instances Calypso (instances/instance-N.env) ── */
let champsInst = [];
async function chargerInstances() {
  const l = await api('/api/instances');
  $('#i-sel').innerHTML = l.map(i => `<option value="${i.n}">${esc(i.role)}${i.existe ? '' : ' — (pas encore de fichier)'}</option>`).join('');
  try { const n = localStorage.getItem('instance'); if (n) $('#i-sel').value = n; } catch (e) { }
  chargerInstance();
}
async function chargerInstance() {
  champsInst = await api('/api/instance?n=' + $('#i-sel').value);
  try { localStorage.setItem('instance', $('#i-sel').value); } catch (e) { }
  dessinerInstance();
}
const dessinerInstance = () => dessinerForm(champsInst, $('#i-form'), $('#i-filtre').value, $('#i-modifiees').checked);
$('#i-sel').onchange = chargerInstance;
$('#i-filtre').oninput = dessinerInstance;
$('#i-modifiees').onchange = dessinerInstance;
$('#i-enr').onclick = async () => {
  const v = modifies($('#i-form'));
  if (!Object.keys(v).length) return msg('Rien de modifié');
  try {
    const r = await api('/api/instance', { n: +$('#i-sel').value, valeurs: v });
    msg(r.fichier + ' écrit : ' + Object.keys(v).join(', '));
    chargerInstances();
  } catch (e) { msg(e.message, false); }
};

/* ── demons (VTY) ── */
let demons = [], cour = null;

async function chargerDemons(force) {
  demons = await api('/api/demons' + (force ? '?rafraichir=1' : ''));
  const avant = $('#d-sel').value;
  $('#d-sel').innerHTML = demons.map((d, i) =>
    `<option value="${i}">${esc(d.nom)} — ${d.hote}:${d.port} (${esc(d.invite)})</option>`).join('');
  if (avant && demons[avant]) $('#d-sel').value = avant;
  if (demons.length) chargerCfg();
}
const demon = () => demons[$('#d-sel').value];

async function chargerCfg() {
  const d = demon();
  if (!d) return;
  $('#d-cfg').textContent = 'lecture…';
  try { cour = await api(`/api/config?hote=${d.hote}&port=${d.port}`); dessinerCfg(); }
  catch (e) { $('#d-cfg').textContent = e.message; }
}

function dessinerCfg() {
  const f = $('#filtre').value.trim().toLowerCase();
  $('#d-cfg').innerHTML = cour.lignes.map((l, i) => {
    if (f && !(l.txt + ' ' + l.chemin.join(' ')).toLowerCase().includes(f)) return '';
    return `<div class="l${l.noeud ? ' noeud' : ''}" style="padding-left:${l.prof * 14}px">
      <input class="t" data-i="${i}" value="${esc(l.txt)}">
      <button class="b2" data-a="ok" data-i="${i}" title="appliquer">✓</button>
      ${l.noeud ? `<button class="b2" data-a="aj" data-i="${i}" title="ajouter une ligne dans ce noeud">+</button>` : ''}
      <button class="b2" data-a="no" data-i="${i}" title="envoyer « no … »">no</button></div>`;
  }).join('');
  $('#d-cfg').querySelectorAll('input.t').forEach(x => {
    x.oninput = () => x.classList.toggle('modifie', x.value !== cour.lignes[x.dataset.i].txt);
    x.onkeydown = e => {
      if (e.key === 'Enter') envoyer(+x.dataset.i, [x.value]);
      if (e.key === 'Escape') { x.value = cour.lignes[x.dataset.i].txt; x.classList.remove('modifie'); }
    };
  });
  $('#d-cfg').querySelectorAll('button').forEach(b => b.onclick = () => {
    const i = +b.dataset.i, l = cour.lignes[i], x = $(`#d-cfg input[data-i="${i}"]`);
    if (b.dataset.a === 'ok') envoyer(i, [x.value]);
    if (b.dataset.a === 'no' && confirm('Envoyer « no ' + l.txt + ' » ?')) envoyer(i, ['no ' + l.txt]);
    if (b.dataset.a === 'aj') { const n = prompt('Ligne à ajouter dans « ' + l.txt + ' » :'); if (n) envoyer(i, [n], true); }
  });
}

async function envoyer(i, lignes, dedans) {
  const d = demon(), l = cour.lignes[i], chemin = dedans ? [...l.chemin, l.txt] : l.chemin;
  try {
    const r = await api('/api/appliquer', { hote: d.hote, port: d.port, chemin, lignes });
    $('#d-jrn').textContent = `[${new Date().toLocaleTimeString()}] ${d.nom} ${d.hote}:${d.port}\n${r.journal}\n\n` + $('#d-jrn').textContent;
    msg(r.ok ? 'Appliqué' : 'Erreur VTY — voir le journal', r.ok);
    if (r.ok) chargerCfg();
  } catch (e) { msg(e.message, false); }
}

async function consoleVty(lignes) {
  const d = demon();
  if (!d) return;
  $('#c-out').textContent = '…';
  try { $('#c-out').textContent = (await api('/api/console', { hote: d.hote, port: d.port, lignes })).sortie; }
  catch (e) { $('#c-out').textContent = e.message; }
}

$('#d-sel').onchange = chargerCfg;
$('#d-ref').onclick = chargerCfg;
$('#d-scan').onclick = () => chargerDemons(true);
$('#filtre').oninput = () => cour && dessinerCfg();
$('#c-go').onclick = () => consoleVty($('#c-in').value.split('\n'));
$('#c-in').onkeydown = e => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) $('#c-go').click(); };
document.querySelectorAll('[data-c]').forEach(b => b.onclick = () => consoleVty([b.dataset.c]));
$('#d-write').onclick = () => {
  const d = demon();
  if (d && confirm('write memory sur ' + d.nom + ' ? (réécrit son fichier de config)')) consoleVty(['write memory']);
};

/* ── fichiers ── */
async function chargerFichiers() {
  const l = await api('/api/fichiers');
  $('#f-sel').innerHTML = l.map(p => `<option>${esc(p)}</option>`).join('');
  chargerFichier();
}
async function chargerFichier() {
  const t = $('#f-txt');
  t.value = (await api('/api/fichier?p=' + encodeURIComponent($('#f-sel').value))).texte;
  t.dataset.orig = t.value;
  t.classList.remove('modifie');
}
$('#f-sel').onchange = chargerFichier;
$('#f-txt').oninput = e => e.target.classList.toggle('modifie', e.target.value !== e.target.dataset.orig);
$('#f-enr').onclick = async () => {
  try { await api('/api/fichier', { p: $('#f-sel').value, texte: $('#f-txt').value }); msg('Enregistré'); chargerFichier(); }
  catch (e) { msg(e.message, false); }
};

/* ── etat ── */
const duree = s => s > 3600 ? (s / 3600 | 0) + 'h' + String((s % 3600) / 60 | 0).padStart(2, '0') : s > 60 ? (s / 60 | 0) + 'm' : s + 's';
async function chargerEtat() {
  const e = await api('/api/etat');
  $('#e-ps').innerHTML = '<tr><th>PID</th><th>Âge</th><th>RSS Mo</th><th>CPU %</th><th>Commande</th></tr>' +
    e.procs.map(p => `<tr><td>${p.pid}</td><td>${duree(p.age)}</td><td>${p.rss}</td><td>${p.cpu}</td><td><code>${esc(p.cmd)}</code></td></tr>`).join('');
  $('#e-vty').innerHTML = '<tr><th>Démon</th><th>Adresse</th><th>Invite</th><th>PID</th></tr>' +
    e.vty.map(d => `<tr><td>${esc(d.nom)}</td><td>${d.hote}:${d.port}</td><td>${esc(d.invite)}</td><td>${d.pid}</td></tr>`).join('');
}

/* ── demarrage ── */
chargerGlobals();
chargerInstances().catch(e => msg(e.message, false));
chargerDemons().catch(e => msg(e.message, false));
chargerFichiers();
try { const o = localStorage.getItem('onglet'); if (o) document.querySelector(`nav button[data-o="${o}"]`)?.click(); } catch (e) { }
