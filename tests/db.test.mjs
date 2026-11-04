// Mandatory database tests (brief §22). Run against a throw-away local database built by
// scripts/local_db.sh + migration/out/load.sql. Uses node:test and real concurrent connections.
//   node --test tests/db.test.mjs
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import pg from 'pg';

const URL = process.env.DATABASE_URL || 'postgresql://postgres@localhost/samples?host=/tmp&port=55432';
const pool = new pg.Pool({ connectionString: URL, max: 20 });
const uuid = () => crypto.randomUUID();
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const users = {};

// Runs fn inside a transaction impersonating a Supabase caller (service | anon | user key).
async function as(who, fn) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    if (who === 'service') {
      await c.query("select set_config('request.jwt.claim.role','service_role',true)");
      await c.query('set local role service_role');
    } else if (who === 'anon') {
      await c.query("select set_config('request.jwt.claim.role','anon',true)");
      await c.query('set local role anon');
    } else {
      await c.query("select set_config('request.jwt.claim.role','authenticated',true), set_config('request.jwt.claim.sub',$1,true)", [users[who]]);
      await c.query('set local role authenticated');
    }
    const out = await fn(c);
    await c.query('commit');
    return out;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally { c.release(); }
}
const one = async (c, sql, args) => (await c.query(sql, args)).rows[0];
const su = async (sql, args) => (await pool.query(sql, args)).rows;   // superuser (test setup only)

async function stockOf(code) {
  return (await su(`select s.id, s.on_hand, s.reserved from stock s join sample_skus k on k.id = s.sku_id where k.code = $1`, [code]))[0];
}
async function setStock(code, onHand) {          // test fixture: absolute count by CESANTONI
  const s = await stockOf(code);
  if (s.reserved > onHand) throw new Error('fixture below reservations');
  return as('ces', (c) => one(c, 'select public.inv_count($1,$2,$3,$4) r', [uuid(), s.id, onHand, 'test fixture count']));
}
function payload(lines, extra = {}) {
  return { full_name: 'Test Customer', company: 'QA', email: `qa+${uuid().slice(0, 8)}@example.com`, phone: '555-0100',
           delivery_method: 'shipping', address_line: '1 Test St', city: 'Houston', state: 'TX', zip_code: '77001', country: 'United States',
           lines, ...extra };
}
async function submit(lines, { key = uuid(), extra = {}, token = 'tok-' + uuid() } = {}) {
  return as('service', (c) => one(c, 'select public.submit_request($1,$2,$3,$4) r', [payload(lines, extra), key, sha(token), 'fp-' + uuid()])).then((x) => ({ ...x.r, token }));
}
async function setStatus(who, requestId, to, extra = {}) {
  return as(who, (c) => one(c, 'select public.request_set_status($1,$2,$3,$4,$5,$6) r',
    [extra.op || uuid(), requestId, to, extra.reason || null, null, extra.exception || false])).then((x) => x.r);
}
const errOf = async (p) => { try { await p; return null; } catch (e) { return e; } };

const SKU_A = 'HOUSTON2-001', SKU_B = 'HOUSTON2-002', SKU_C = 'HOUSTON2-003', SKU_FULL = 'HOUSTON2-031';

before(async () => {
  for (const [k, role, org] of [['admin', 'admin', 'CESANTONI'], ['ces', 'cesantoni', 'CESANTONI'], ['armex', 'armex', 'ARMEX'],
                                ['billing', 'billing', 'CESANTONI'], ['client', 'client', 'CLIENT'], ['inactive', 'armex', 'ARMEX']]) {
    const id = uuid(); users[k] = id;
    await su('insert into auth.users (id, email) values ($1,$2)', [id, `${k}@test.local`]);
    await su(`insert into profiles (user_id, email, full_name, org_id, role, active)
              select $1,$2,$3,id,$4,$5 from organizations where code=$6`, [id, `${k}@test.local`, k, role, k !== 'inactive', org]);
  }
  // publish a few SKUs for the tests (CESANTONI decision in production)
  await su(`update sample_skus set public_enabled = true, catalog_verified = true where code = any($1)`, [[SKU_A, SKU_B, SKU_C, SKU_FULL]]);
  await su(`update settings set value = 'false' where key = 'require_validated_image'`);
  await su(`update settings set value = '1000' where key in ('rate_limit_per_hour','rate_limit_per_email_day')`);
});
after(() => pool.end());

test('1. two simultaneous requests cannot reserve the same last pieces', async () => {
  await setStock(SKU_A, 3);
  const before_ = await stockOf(SKU_A);
  const avail = before_.on_hand - before_.reserved;
  const results = await Promise.allSettled(Array.from({ length: 6 }, () => submit([{ sku_code: SKU_A, quantity: avail }])));
  const ok = results.filter((r) => r.status === 'fulfilled');
  const ko = results.filter((r) => r.status === 'rejected');
  assert.equal(ok.length, 1, 'exactly one request wins the last pieces');
  assert.ok(ko.every((r) => r.reason.message === 'UNAVAILABLE'), ko.map((r) => r.reason.message).join());
  const after_ = await stockOf(SKU_A);
  assert.equal(after_.reserved, before_.reserved + avail);
  assert.ok(after_.reserved <= after_.on_hand);
  // the losing customer gets the exact problem to fix the selection
  assert.match(ko[0].reason.detail, /insufficient/);
});

test('2. double click (same idempotency key) creates one request', async () => {
  await setStock(SKU_B, 50);
  const key = uuid();
  const [a, b] = await Promise.all([submit([{ sku_code: SKU_B, quantity: 2 }], { key }), submit([{ sku_code: SKU_B, quantity: 2 }], { key })]);
  assert.equal(a.folio, b.folio);
  assert.equal((await su('select count(*)::int n from requests where idempotency_key = $1', [key]))[0].n, 1);
  assert.equal((await su(`select count(*)::int n from inventory_movements where op_id = $1 and movement = 'reserve'`, [key]))[0].n, 1);
});

test('3. retrying an operation does not duplicate movements', async () => {
  const s = await stockOf(SKU_C);
  const op = uuid();
  const r1 = await as('ces', (c) => one(c, 'select public.inv_adjust($1,$2,$3,$4) r', [op, s.id, 5, 'received from showroom']));
  const r2 = await as('ces', (c) => one(c, 'select public.inv_adjust($1,$2,$3,$4) r', [op, s.id, 5, 'received from showroom']));
  assert.equal(r1.r.replayed, false); assert.equal(r2.r.replayed, true);
  assert.equal((await stockOf(SKU_C)).on_hand, s.on_hand + 5);
  assert.equal((await su('select count(*)::int n from inventory_movements where op_id = $1', [op]))[0].n, 1);
});

test('4. a reservation does not touch physical stock', async () => {
  const s0 = await stockOf(SKU_B);
  await submit([{ sku_code: SKU_B, quantity: 3 }]);
  const s1 = await stockOf(SKU_B);
  assert.equal(s1.on_hand, s0.on_hand);
  assert.equal(s1.reserved, s0.reserved + 3);
});

async function prepareAndPack(req) {
  const lines = await su('select id, quantity from request_lines where request_id = $1', [req.request_id]);
  await as('armex', (c) => c.query('select public.package_create($1,$2,$3,$4)', [uuid(), req.request_id,
    JSON.stringify(lines.map((l) => ({ request_line_id: l.id, quantity: l.quantity }))), 'Bench 1']));
  await setStatus('armex', req.request_id, 'ready');
}

test('5. physical exit deducts exactly once (shipping)', async () => {
  const s0 = await stockOf(SKU_B);
  const req = await submit([{ sku_code: SKU_B, quantity: 4 }]);
  await prepareAndPack(req);
  // cannot ship without tracking
  assert.match((await errOf(setStatus('armex', req.request_id, 'shipped'))).message, /MISSING_STEPS/);
  await as('armex', (c) => c.query('select public.shipment_register($1,$2,$3,$4,$5)', [uuid(), req.request_id, 'UPS', '1Z TEST ' + Date.now(), 18.5]));
  const op = uuid();
  await setStatus('armex', req.request_id, 'shipped', { op });
  await setStatus('armex', req.request_id, 'shipped', { op });                     // retry of the same scan
  assert.match((await errOf(setStatus('armex', req.request_id, 'shipped'))).message, /INVALID_TRANSITION/); // new scan
  const s1 = await stockOf(SKU_B);
  assert.equal(s1.on_hand, s0.on_hand - 4);
  assert.equal(s1.reserved, s0.reserved);
  assert.equal((await su(`select count(*)::int n from inventory_movements where request_id = $1 and movement = 'ship'`, [req.request_id]))[0].n, 1);
  // delivered requires the shipped step; it is now allowed
  assert.equal((await setStatus('armex', req.request_id, 'delivered')).status, 'delivered');
});

test('5b. pickup deducts at collection and requires proof', async () => {
  const s0 = await stockOf(SKU_B);
  const req = await submit([{ sku_code: SKU_B, quantity: 1 }], { extra: { delivery_method: 'pickup', address_line: null, city: null } });
  await prepareAndPack(req);
  assert.match((await errOf(setStatus('armex', req.request_id, 'shipped'))).message, /only applies to shipping/);
  await setStatus('armex', req.request_id, 'ready_for_pickup');
  assert.equal((await stockOf(SKU_B)).on_hand, s0.on_hand, 'no deduction before collection');
  assert.match((await errOf(setStatus('armex', req.request_id, 'collected'))).message, /pickup proof/);
  await as('armex', (c) => c.query(`select public.evidence_register($1,$2,'pickup_proof',$3,'image/jpeg',1200,$4)`,
    [uuid(), req.request_id, `${req.folio}/pickup-${uuid()}.jpg`, sha(uuid())]));
  await setStatus('armex', req.request_id, 'collected');
  assert.equal((await stockOf(SKU_B)).on_hand, s0.on_hand - 1);
  const r = await su('select address_line from requests where id = $1', [req.request_id]);
  assert.equal(r[0].address_line, null, 'pickup stores no shipping address');
});

test('6. cancellation releases only its own reservations; after exit nothing is restocked', async () => {
  const s0 = await stockOf(SKU_B);
  const keep = await submit([{ sku_code: SKU_B, quantity: 2 }]);
  const cancel = await submit([{ sku_code: SKU_B, quantity: 5 }]);
  assert.match((await errOf(setStatus('armex', cancel.request_id, 'cancelled', { reason: 'customer asked' }))).message, /permission denied/);
  await setStatus('ces', cancel.request_id, 'cancelled', { reason: 'customer asked' });
  const s1 = await stockOf(SKU_B);
  assert.equal(s1.reserved, s0.reserved + 2);
  assert.equal(s1.on_hand, s0.on_hand);
  const act = await su(`select status, count(*)::int n from reservations where request_id = $1 group by status`, [keep.request_id]);
  assert.deepEqual(act, [{ status: 'active', n: 1 }]);
  // cancel after the exit: no automatic restock
  const shipped = await submit([{ sku_code: SKU_B, quantity: 1 }]);
  await prepareAndPack(shipped);
  await as('armex', (c) => c.query('select public.shipment_register($1,$2,$3,$4)', [uuid(), shipped.request_id, 'UPS', '1ZCANCEL' + Date.now()]));
  await setStatus('armex', shipped.request_id, 'shipped');
  const s2 = await stockOf(SKU_B);
  await setStatus('ces', shipped.request_id, 'cancelled', { reason: 'lost by carrier' });
  assert.deepEqual(await stockOf(SKU_B), s2);
});

test('7. a return needs confirmed reception and condition', async () => {
  const req = await submit([{ sku_code: SKU_B, quantity: 2 }]);
  await prepareAndPack(req);
  await as('armex', (c) => c.query('select public.shipment_register($1,$2,$3,$4)', [uuid(), req.request_id, 'UPS', '1ZRET' + Date.now()]));
  await setStatus('armex', req.request_id, 'shipped');
  const line = (await su('select id from request_lines where request_id = $1', [req.request_id]))[0];
  const s = await stockOf(SKU_B);
  const call = (qty, ok, at) => as('ces', (c) => one(c, 'select public.inv_return_receipt($1,$2,$3,$4,$5,$6,$7) r', [uuid(), line.id, s.id, qty, ok, 'returned by customer', at]));
  assert.match((await errOf(call(1, true, null))).message, /reception date is required/);
  assert.equal((await call(1, false, new Date())).r.status, 'not_restocked');
  assert.equal((await stockOf(SKU_B)).on_hand, s.on_hand);
  assert.equal((await call(2, true, new Date())).r.status, 'restocked');
  assert.match((await errOf(call(1, true, new Date()))).message, /RETURN_EXCEEDS_SHIPPED/);
  assert.equal((await stockOf(SKU_B)).on_hand, s.on_hand + 2);
  assert.match((await errOf(as('armex', (c) => c.query('select public.inv_return_receipt($1,$2,$3,$4,$5,$6,$7)', [uuid(), line.id, s.id, 1, true, 'x x', new Date()])))).message, /permission denied/);
});

test('8. a bulk count keeps history and reservations; stale preview is refused', async () => {
  const s = await stockOf(SKU_B);
  const movesBefore = (await su('select count(*)::int n from inventory_movements'))[0].n;
  const file = sha('count-' + uuid());
  const rows = [{ row_no: 2, sku_code: SKU_B, furniture: 'A', position: '2', quantity: String(s.reserved + 7) },
                { row_no: 3, sku_code: 'NOPE-1', furniture: 'A', position: '9', quantity: '3' },
                { row_no: 4, sku_code: SKU_B, furniture: 'A', position: '2', quantity: '1' }];
  const pv = await as('ces', (c) => one(c, `select public.import_preview('count_absolute',$1,$2,$3) r`, ['count.xlsx', file, JSON.stringify(rows)]));
  assert.deepEqual([pv.r.valid, pv.r.rejected], [1, 2]);
  // inventory changes after the preview → apply must stop
  await as('ces', (c) => c.query('select public.inv_adjust($1,$2,1,$3)', [uuid(), s.id, 'found one more']));
  const st = await as('ces', (c) => one(c, 'select public.import_apply($1,$2,$3) r', [uuid(), pv.r.import_id, 'monthly count']));
  assert.equal(st.r.status, 'stale');
  // new preview, then apply
  const pv2 = await as('ces', (c) => one(c, `select public.import_preview('count_absolute',$1,$2,$3) r`, ['count.xlsx', file, JSON.stringify(rows.slice(0, 1))]));
  const ap = await as('ces', (c) => one(c, 'select public.import_apply($1,$2,$3) r', [uuid(), pv2.r.import_id, 'monthly count']));
  assert.equal(ap.r.status, 'applied');
  const s2 = await stockOf(SKU_B);
  assert.equal(s2.on_hand, s.reserved + 7);
  assert.equal(s2.reserved, s.reserved, 'reservations untouched');
  assert.ok((await su('select count(*)::int n from inventory_movements'))[0].n > movesBefore, 'history only grows');
  // a count below reservations is held for review
  const low = [{ row_no: 2, sku_code: SKU_B, furniture: 'A', position: '2', quantity: String(Math.max(s2.reserved - 1, 0)) }];
  if (s2.reserved > 0) {
    const pv3 = await as('ces', (c) => one(c, `select public.import_preview('count_absolute',$1,$2,$3) r`, ['low.xlsx', sha(uuid()), JSON.stringify(low)]));
    assert.equal(pv3.r.review, 1);
    assert.match((await errOf(as('ces', (c) => c.query('select public.import_apply($1,$2,$3)', [uuid(), pv3.r.import_id, 'count'])))).message, /IMPORT_NEEDS_REVIEW/);
    const single = await as('ces', (c) => one(c, 'select public.inv_count($1,$2,$3,$4) r', [uuid(), s2.id, s2.reserved - 1, 'count']));
    assert.equal(single.r.status, 'review');
  }
  // 9. the same file cannot be applied twice
  assert.match((await errOf(as('ces', (c) => c.query(`select public.import_preview('count_absolute',$1,$2,$3)`, ['count.xlsx', file, JSON.stringify(rows.slice(0, 1))])))).message, /DUPLICATE_FILE/);
  // receipt ≠ count: a receipt adds
  const pr = await as('ces', (c) => one(c, `select public.import_preview('receipt',$1,$2,$3) r`, ['in.xlsx', sha(uuid()), JSON.stringify([{ row_no: 2, sku_code: SKU_B, furniture: 'A', position: '2', quantity: '10' }])]));
  await as('ces', (c) => c.query('select public.import_apply($1,$2,$3)', [uuid(), pr.r.import_id, 'shipment from Mexico']));
  assert.equal((await stockOf(SKU_B)).on_hand, s2.on_hand + 10);
});

test('10. permissions are enforced by the database, not the browser', async () => {
  const s = await stockOf(SKU_C);
  for (const who of ['armex', 'billing', 'client', 'inactive']) {
    const e = await errOf(as(who, (c) => c.query('select public.inv_adjust($1,$2,$3,$4)', [uuid(), s.id, 100, 'free adjustment'])));
    assert.ok(e && (e.code === '42501'), `${who} must not adjust stock (${e && e.message})`);
  }
  assert.ok(await errOf(as('ces', (c) => c.query('update stock set on_hand = 999 where id = $1', [s.id]))), 'no direct table writes');
  assert.ok(await errOf(as('anon', (c) => c.query('select public.submit_request($1,$2,$3)', [payload([]), uuid(), sha('x')]))), 'anon cannot bypass the server');
  assert.ok(await errOf(as('client', (c) => c.query('select public.request_set_status($1,1,$2)', [uuid(), 'delivered']))));
  assert.ok(await errOf(as('billing', (c) => c.query('select public.package_create($1,1,$2)', [uuid(), '[]']))));
  // ARMEX cannot read invoices; billing cannot read stock; client sees only own requests
  assert.equal((await as('armex', (c) => c.query('select * from invoices'))).rowCount, 0);
  assert.equal((await as('billing', (c) => c.query('select * from stock'))).rowCount, 0);
  assert.equal((await as('client', (c) => c.query('select * from requests'))).rowCount, 0);
  assert.equal((await as('inactive', (c) => c.query('select * from requests'))).rowCount, 0, 'deactivated user loses access');
  assert.equal((await as('anon', (c) => c.query('select * from public.catalog_items()'))).rowCount > 0, true);
  assert.ok(await errOf(as('anon', (c) => c.query('select * from requests'))));
  // the last active admin cannot be removed
  assert.match((await errOf(su('update profiles set active = false where role = $1', ['admin']))).message, /at least one active administrator/);
});

test('11. private evidence is not readable without authorization; evidence cannot be deleted', async () => {
  await su(`insert into storage.objects (bucket_id, name) values ('evidence', 'SMCES-9999/secret.jpg')`);
  assert.equal((await as('anon', (c) => c.query(`select * from storage.objects where bucket_id = 'evidence'`))).rowCount, 0);
  assert.equal((await as('client', (c) => c.query(`select * from storage.objects where bucket_id = 'evidence'`))).rowCount, 0);
  assert.equal((await as('billing', (c) => c.query(`select * from storage.objects where bucket_id = 'evidence'`))).rowCount, 0);
  assert.ok((await as('armex', (c) => c.query(`select * from storage.objects where bucket_id = 'evidence'`))).rowCount >= 1);
  assert.equal((await as('ces', (c) => c.query(`delete from storage.objects where bucket_id = 'evidence'`))).rowCount, 0, 'no delete policy');
  assert.ok(await errOf(su('delete from evidences')), 'evidence rows are append-only');
  assert.ok(await errOf(su('update inventory_movements set quantity = 0')), 'movements are append-only');
});

test('13. a repeated event does not queue duplicated emails; workers do not double-claim', async () => {
  const req = await submit([{ sku_code: SKU_B, quantity: 1 }]);
  const n0 = (await su('select count(*)::int n from notifications where request_id = $1', [req.request_id]))[0].n;
  await as('service', (c) => c.query(`select app.enqueue_notification('request_confirmed', $1)`, [req.request_id]));
  await as('service', (c) => c.query(`select app.enqueue_notification('request_confirmed', $1)`, [req.request_id]));
  const n1 = (await su('select count(*)::int n from notifications where request_id = $1', [req.request_id]))[0].n;
  assert.equal(n1, n0);
  assert.equal(n0, 1 + 7, 'customer + 7 configured internal recipients');
  const [a, b] = await Promise.all([as('service', (c) => c.query('select * from public.notifications_claim(500)')),
                                    as('service', (c) => c.query('select * from public.notifications_claim(500)'))]);
  const ids = [...a.rows, ...b.rows].map((r) => r.notifications_claim.id);
  assert.equal(new Set(ids).size, ids.length, 'no notification claimed twice');
  const first = ids[0];
  await as('service', (c) => c.query('select public.notifications_result($1,false,null,$2)', [first, 'timeout']));
  const f = (await su('select status, next_attempt_at > now() as later from notifications where id = $1', [first]))[0];
  assert.deepEqual(f, { status: 'failed', later: true });
});

test('15. public catalog hides combinations without availability; tracking needs the token', async () => {
  await setStock(SKU_C, (await stockOf(SKU_C)).reserved);   // nothing available
  const cat = await as('anon', (c) => c.query('select sku_code from public.catalog_items()'));
  assert.ok(!cat.rows.some((r) => r.sku_code === SKU_C));
  assert.ok(!cat.rows.some((r) => r.sku_code === 'HOUSTON2-004'), 'unpublished SKU stays hidden');
  const req = await submit([{ sku_code: SKU_B, quantity: 1 }], { token: 'secret-token-123' });
  const ok = await as('anon', (c) => one(c, 'select public.track_request($1,$2) r', [req.folio, 'secret-token-123']));
  assert.equal(ok.r.folio, req.folio);
  assert.equal(ok.r.email, undefined, 'no personal data in tracking');
  assert.match((await errOf(as('anon', (c) => c.query('select public.track_request($1,$2)', [req.folio, 'guess'])))).message, /NOT_FOUND/);
});

test('extra: validation, limits, legacy snapshot, folio format', async () => {
  assert.match((await errOf(submit([{ sku_code: SKU_FULL, quantity: 2 }]))).detail, /quantity_limit/);
  assert.match((await errOf(submit([{ sku_code: 'HOUSTON2-004', quantity: 1 }]))).detail, /not_available/);
  assert.ok(await errOf(submit([{ sku_code: SKU_B, quantity: 1 }], { extra: { city: '' } })), 'shipping needs full address');
  const r = await submit([{ sku_code: SKU_B, quantity: 1 }]);
  assert.match(r.folio, /^SMCES-\d{4,}$/);
  assert.ok(Number(r.folio.split('-')[1]) > 12, 'new folios continue after the legacy ones');
  await su(`update products set display_name_en = 'Renamed' where model = 'CARAVITA'`);
  const snap = await su('select snap_description from request_lines where request_id = $1', [r.request_id]);
  assert.doesNotMatch(snap[0].snap_description, /Renamed/);
  assert.ok(await errOf(su(`update request_lines set snap_description = 'x' where request_id = $1`, [r.request_id])));
});

test('public submission from the website (anon role, no server function)', async () => {
  await setStock(SKU_B, (await stockOf(SKU_B)).reserved + 20);
  const body = (extra = {}) => ({ ...payload([{ sku_code: SKU_B, quantity: 2 }]), form_started_at: Date.now() - 10000, ...extra });
  const call = (b, key = uuid()) => as('anon', (c) => one(c, 'select public.submit_request_public($1,$2) r', [b, key])).then((x) => x.r);
  // bots and invalid data are rejected with field messages, nothing is stored
  assert.match((await errOf(call(body({ website: 'spam' })))).message, /VALIDATION/);
  assert.match((await errOf(call(body({ form_started_at: Date.now() })))).message, /VALIDATION/);
  const bad = await errOf(call(body({ email: 'nope', city: '' })));
  assert.deepEqual(Object.keys(JSON.parse(bad.detail)).sort(), ['city', 'email']);
  // double click: same key → same folio and same private link
  const key = uuid(); const b = body();
  const [r1, r2] = await Promise.all([call(b, key), call(b, key)]);
  assert.equal(r1.folio, r2.folio); assert.equal(r1.track_token, r2.track_token);
  assert.equal((await su('select count(*)::int n from requests where idempotency_key = $1', [key]))[0].n, 1);
  // the token opens tracking; the folio alone does not
  const t = await as('anon', (c) => one(c, 'select public.track_request($1,$2) r', [r1.folio, r1.track_token]));
  assert.equal(t.r.status, 'reserved');
  // anon still cannot call the server-only function or the worker
  assert.ok(await errOf(as('anon', (c) => c.query('select public.submit_request($1,$2,$3)', [b, uuid(), sha('x')]))));
  assert.ok(await errOf(as('anon', (c) => c.query(`select public.notification_track_token($1)`, [r1.folio]))));
  assert.equal((await as('service', (c) => one(c, 'select public.notification_track_token($1) t', [r1.folio]))).t, r1.track_token);
});
