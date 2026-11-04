// POST /functions/v1/submit-request  — public endpoint of the sample request form.
// Validates input, applies anti-abuse checks, then calls public.submit_request (one DB transaction).
// Secrets (Supabase › Edge Functions › Secrets): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (automatic),
//   TRACKING_SECRET, FINGERPRINT_SALT, ALLOWED_ORIGINS (comma separated), PUBLIC_SITE_URL, TURNSTILE_SECRET (optional)
import { validateRequest, looksAutomated, sha256Hex, trackingToken, mapDbError } from '../_shared/request.ts';

const env = (k: string) => Deno.env.get(k) || '';
const allowed = env('ALLOWED_ORIGINS').split(',').map((s) => s.trim()).filter(Boolean);

function cors(origin: string | null) {
  const ok = origin && allowed.includes(origin);
  return { 'Access-Control-Allow-Origin': ok ? origin! : allowed[0] || 'null', 'Access-Control-Allow-Methods': 'POST, OPTIONS',
           'Access-Control-Allow-Headers': 'content-type, idempotency-key', 'Vary': 'Origin' };
}
const json = (status: number, body: unknown, h: Record<string, string>) =>
  new Response(JSON.stringify(body), { status, headers: { ...h, 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: h });
  if (req.method !== 'POST') return json(405, { error: 'method' }, h);
  if (!allowed.includes(req.headers.get('origin') || '')) return json(403, { error: 'origin' }, h);
  const key = req.headers.get('idempotency-key') || '';
  if (!/^[0-9a-f-]{36}$/i.test(key)) return json(400, { error: 'validation', message: 'Please reload the page and try again.' }, h);

  let body: any; try { body = await req.json(); } catch { return json(400, { error: 'validation', message: 'Invalid request.' }, h); }
  if (looksAutomated(body)) return json(400, { error: 'validation', message: 'Please review the form and submit it again.' }, h);
  if (env('TURNSTILE_SECRET')) {
    const v = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST',
      body: new URLSearchParams({ secret: env('TURNSTILE_SECRET'), response: String(body.captcha || '') }) }).then((r) => r.json()).catch(() => ({}));
    if (!v.success) return json(400, { error: 'captcha', message: 'Please complete the verification.' }, h);
  }
  const { payload, errors } = validateRequest(body);
  if (!payload) return json(400, { error: 'validation', fields: errors, message: 'Please review the highlighted fields.' }, h);

  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim();
  const day = new Date().toISOString().slice(0, 10);
  const fingerprint = (await sha256Hex(`${env('FINGERPRINT_SALT')}:${day}:${ip}`)).slice(0, 32);   // the raw IP is never stored
  const token = await trackingToken(env('TRACKING_SECRET'), key);

  const r = await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/submit_request`, {
    method: 'POST',
    headers: { apikey: env('SUPABASE_SERVICE_ROLE_KEY'), Authorization: `Bearer ${env('SUPABASE_SERVICE_ROLE_KEY')}`, 'content-type': 'application/json' },
    body: JSON.stringify({ p_payload: payload, p_idempotency_key: key, p_token_hash: await sha256Hex(token), p_fingerprint: fingerprint }),
  });
  const out = await r.json().catch(() => ({}));
  if (!r.ok) { const m = mapDbError(out); if (m.status === 500) console.error('submit_request', out); return json(m.status, m.body, h); }
  const site = env('PUBLIC_SITE_URL').replace(/\/$/, '');
  return json(200, { folio: out.folio, track_url: `${site}/track/?f=${encodeURIComponent(out.folio)}&t=${token}` }, h);
});
