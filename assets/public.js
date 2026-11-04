// Public area (English). Data comes only from the central database through its public API:
//   catalog  → rpc/catalog_items (anon key, read-only, filtered by the database)
//   request  → functions/v1/submit-request (server validates, reserves and creates the folio)
//   tracking → rpc/track_request (folio + secret token from the email link)
// The browser only keeps the temporary selection (cart) — never inventory, requests or users.
const CFG = window.SAMPLES_CONFIG;

// Works with the legacy "anon" JWT key (eyJ…) and with the new publishable key (sb_publishable_…).
export function apiHeaders(extra = {}) {
  const h = { apikey: CFG.anonKey, 'content-type': 'application/json', ...extra };
  if (/^eyJ/.test(CFG.anonKey)) h.Authorization = `Bearer ${CFG.anonKey}`;
  return h;
}

export async function rpc(fn, args = {}) {
  const r = await fetch(`${CFG.supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: apiHeaders(),
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => null);
  if (!r.ok) { const e = new Error((body && body.message) || `HTTP ${r.status}`); e.status = r.status; e.body = body; throw e; }
  return body;
}

export function imageUrl(path) {
  if (!path) return null;
  if (/^https?:\/\//.test(path)) return path;
  // photos stored in this repository (assets/products/…) or in the Supabase "catalog-images" bucket
  if (path.startsWith('assets/')) return (CFG.basePath || '/') + path;
  return `${CFG.supabaseUrl}/storage/v1/object/public/catalog-images/${path.split('/').map(encodeURIComponent).join('/')}`;
}

export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const titleCase = (s) => String(s || '').toLowerCase().replace(/(^|[\s-])\S/g, (m) => m.toUpperCase());

// ------------------------------------------------------------------ cart (temporary, per browser)
const KEY = 'cesantoni-samples-cart-v1';
export const cart = {
  read() { try { const v = JSON.parse(localStorage.getItem(KEY) || '[]'); return Array.isArray(v) ? v : []; } catch { return []; } },
  write(items) { try { localStorage.setItem(KEY, JSON.stringify(items)); } catch { /* private mode: selection lasts for this page only */ } updateCount(); },
  add(item, qty) {
    const items = this.read(); const i = items.findIndex((x) => x.sku_code === item.sku_code);
    if (i >= 0) items[i].quantity = Math.min(items[i].quantity + qty, item.max_selectable);
    else items.push({ ...item, quantity: Math.min(qty, item.max_selectable) });
    this.write(items);
  },
  clear() { this.write([]); },
};
export function updateCount() {
  const n = cart.read().length;
  document.querySelectorAll('[data-cart-count]').forEach((el) => { el.textContent = n; el.hidden = n === 0; });
}

export function header(active) {
  const base = CFG.basePath || '/';
  const a = (href, label, key, extra = '') => `<a href="${base}${href}" ${active === key ? 'aria-current="page"' : ''}>${label}${extra}</a>`;
  document.body.insertAdjacentHTML('afterbegin', `<header class="top"><div class="in">
    <a class="logo" href="${base}" aria-label="CESANTONI Porcelanato Premium — samples catalog"><img src="${base}assets/img/logo-porcelanato-blanco.png" alt="CESANTONI Porcelanato Premium"></a>
    <nav aria-label="Main">${a('', 'Catalog', 'catalog')}${a('request/', 'Request', 'request', ' <span class="count" data-cart-count hidden>0</span>')}${a('track/', 'Track', 'track')}</nav>
  </div></header>`);
  document.body.insertAdjacentHTML('beforeend', `<footer class="site"><div class="in">
    <span>© ${new Date().getFullYear()} CESANTONI · Porcelanato Premium · Samples</span>
    <img src="${base}assets/img/logo-somos-logistica.png" alt="Somos Logística CESANTONI"></div></footer>`);
  updateCount();
}

let toastTimer;
export function toast(msg) {
  let t = document.querySelector('.toast');
  if (!t) { t = document.createElement('div'); t.className = 'toast'; t.setAttribute('role', 'status'); document.body.append(t); }
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}

export const SAMPLE_TYPE = { cut_sample: 'Cut sample', full_piece: 'Full piece' };
export const SAMPLE_HELP = { cut_sample: 'A piece cut from the tile to show color and texture.', full_piece: 'One complete tile in its production format.' };
