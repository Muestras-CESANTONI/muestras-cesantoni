// Local stand-in for Supabase (tests only): serves web/ and emulates
//   POST /rest/v1/rpc/<fn>              → executes the SQL function as role anon (like PostgREST)
//   POST /functions/v1/submit-request   → same validation module as the Edge Function, then submit_request as service_role
// Run: node --experimental-strip-types scripts/dev_server.ts   (DATABASE_URL, PORT)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { validateRequest, looksAutomated, sha256Hex, trackingToken, mapDbError } from '../supabase/functions/_shared/request.ts';

const require = createRequire(import.meta.url);
const pg = require('../tests/node_modules/pg');
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL || 'postgresql://postgres@localhost/samples?host=/tmp&port=55432' });
pool.on('error', (e: any) => console.error('pool error (database restarted?):', e.message));
const PORT = Number(process.env.PORT || 8787);
const ROOT = path.resolve(import.meta.dirname, '..');
const SECRET = 'local-dev-tracking-secret';
const TYPES: Record<string, string> = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png',
  '.otf': 'font/otf', '.ttf': 'font/ttf', '.json': 'application/json', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg' };
const PUBLIC_RPC = new Set(['catalog_items', 'track_request', 'submit_request_public']);

async function asRole(role: 'anon' | 'service_role', sql: string, args: unknown[]) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query(`select set_config('request.jwt.claim.role', $1, true)`, [role]);
    await c.query(`set local role ${role}`);
    const r = await c.query(sql, args);
    await c.query('commit');
    return r;
  } catch (e) { await c.query('rollback').catch(() => {}); throw e; } finally { c.release(); }
}
const send = (res: http.ServerResponse, status: number, body: unknown) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
const readBody = (req: http.IncomingMessage) => new Promise<string>((ok) => { let s = ''; req.on('data', (d) => (s += d)); req.on('end', () => ok(s)); });

http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://localhost:${PORT}`);
  try {
    if (url.pathname === '/config.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(`window.SAMPLES_CONFIG={supabaseUrl:'http://localhost:${PORT}',anonKey:'local',submitUrl:'http://localhost:${PORT}/functions/v1/submit-request',basePath:'/'};`);
    }
    const m = url.pathname.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/);
    if (m && req.method === 'POST') {
      if (!PUBLIC_RPC.has(m[1])) return send(res, 404, { message: 'not exposed in dev server' });
      const args = JSON.parse((await readBody(req)) || '{}');
      const keys = Object.keys(args);
      const sql = `select * from public.${m[1]}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})`;
      try {
        const r = await asRole('anon', sql, keys.map((k) => args[k]));
        const rows = r.rows;
        return send(res, 200, rows.length === 1 && m[1] in rows[0] ? rows[0][m[1]] : rows);
      } catch (e: any) { return send(res, e.code === 'P0002' ? 404 : 400, { message: e.message, code: e.code, details: e.detail }); }
    }
    if (url.pathname === '/functions/v1/submit-request' && req.method === 'POST') {
      const key = String(req.headers['idempotency-key'] || '');
      if (!/^[0-9a-f-]{36}$/i.test(key)) return send(res, 400, { error: 'validation', message: 'Please reload the page and try again.' });
      let body: any;
      try { body = JSON.parse(await readBody(req)); } catch { return send(res, 400, { error: 'validation' }); }
      if (looksAutomated(body)) return send(res, 400, { error: 'validation', message: 'Please review the form and submit it again.' });
      const { payload, errors } = validateRequest(body);
      if (!payload) return send(res, 400, { error: 'validation', fields: errors, message: 'Please review the highlighted fields.' });
      const token = await trackingToken(SECRET, key);
      try {
        const r = await asRole('service_role', 'select public.submit_request($1,$2,$3,$4) r', [payload, key, await sha256Hex(token), 'dev-local']);
        const out = r.rows[0].r;
        return send(res, 200, { folio: out.folio, track_url: `http://localhost:${PORT}/track/?f=${encodeURIComponent(out.folio)}&t=${token}` });
      } catch (e: any) {
        const mm = mapDbError({ message: e.message, code: e.code, detail: e.detail });
        return send(res, mm.status, mm.body);
      }
    }
    let p = path.join(ROOT, decodeURIComponent(url.pathname));
    if (!p.startsWith(ROOT)) return send(res, 403, {});
    if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, 'index.html');
    if (!fs.existsSync(p)) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': TYPES[path.extname(p)] || 'application/octet-stream' });
    fs.createReadStream(p).pipe(res);
  } catch (e: any) { send(res, 500, { message: e.message }); }
}).listen(PORT, () => console.log(`dev server http://localhost:${PORT}`));
