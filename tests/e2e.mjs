// End-to-end check of the public area against the local stand-in API (scripts/dev_server.ts).
// node tests/e2e.mjs [baseUrl] [screenshotDir]
import { createRequire as _cr } from 'node:module';
const { chromium, devices } = _cr(import.meta.url)(process.env.PLAYWRIGHT_PATH || 'playwright');
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const pg = require('./node_modules/pg');

const RUN = Date.now();
const BASE = process.argv[2] || 'http://localhost:8787';
const SHOTS = process.argv[3] || '/tmp';
const db = new pg.Client({ connectionString: process.env.DATABASE_URL || 'postgresql://postgres@localhost/samples?host=/tmp&port=55432' });
await db.connect();
const stock = async (code) => (await db.query('select sum(on_hand)::int on_hand, sum(reserved)::int reserved from stock s join sample_skus k on k.id=s.sku_id where k.code=$1', [code])).rows[0];
const results = [];
const check = async (name, fn) => { try { await fn(); results.push(['PASS', name]); } catch (e) { results.push(['FAIL', name, e.message.split('\n')[0]]); } };

const browser = await chromium.launch();
for (const [label, ctxOpts] of [['desktop', { viewport: { width: 1366, height: 900 } }], ['mobile', { ...devices['iPhone 13'] }]]) {
  const ctx = await browser.newContext(ctxOpts);
  const page = await ctx.newPage();
  const errors = []; page.on('pageerror', (e) => errors.push(e.message));

  await check(`${label}: catalog loads from the database, English, filters`, async () => {
    await page.goto(BASE + '/');
    await page.waitForSelector('.card');
    assert.equal(await page.locator('.card').count(), 10);
    const labels = await page.locator('.filters label').allTextContents();
    assert.deepEqual(labels.map((l) => l.split('\n')[0].trim().replace(/All.*$/, '').trim()), ['Color', 'Finish', 'Samples Size']);
    assert.ok(!(await page.content()).includes('Houston Inventory'));
    await page.getByRole('tab', { name: 'Pavers' }).click();
    assert.equal(await page.locator('.card').count(), 3);
    const finishes = await page.locator('select[name=finish] option').allTextContents();
    assert.deepEqual(finishes, ['All finishes', 'Grip'], 'Pavers only show their own finishes');
    await page.getByRole('tab', { name: 'All' }).click();
    await page.selectOption('select[name=finish]', 'Velvet');
    assert.equal(await page.locator('.card').count(), 2);
    await page.locator('.filters button[type=reset]').click();
    await page.waitForFunction(() => document.querySelectorAll('.card').length === 10);
    if (label === 'mobile') {
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
      assert.equal(overflow, false, 'no horizontal scroll on phone');
    }
    await page.screenshot({ path: `${SHOTS}/e2e-${label}-catalog.png`, fullPage: label === 'desktop' });
  });

  await check(`${label}: add samples, pickup hides address, submit once (double click), get folio`, async () => {
    await page.locator('.card', { hasText: 'Kingston' }).first().locator('[data-add]').click();
    const card = page.locator('.card', { hasText: 'Caravita' }).filter({ hasText: 'Gold' });
    await card.locator('input[type=number]').fill('3');
    await card.locator('[data-add]').click();
    await page.getByRole('link', { name: /Request/ }).click();
    await page.waitForSelector('.sel-line');
    assert.equal(await page.locator('.sel-line').count(), 2);
    await page.fill('#full_name', 'QA Playwright'); await page.fill('#email', `qa-${label}-${RUN}@example.com`); await page.fill('#phone', '713 555 0100');
    await page.locator('label', { hasText: 'Customer pickup' }).click();
    assert.equal(await page.locator('#address_line').isVisible(), false, 'no address for pickup');
    const before = await stock('HOUSTON2-002');
    await page.waitForTimeout(3100);           // the anti-bot check needs a few human seconds
    await page.screenshot({ path: `${SHOTS}/e2e-${label}-request.png`, fullPage: label === 'desktop' });
    await page.locator('#submit').dblclick();
    await page.waitForSelector('.folio');
    const folio = (await page.locator('.folio').textContent()).trim();
    assert.match(folio, /^SMCES-\d{4}$/);
    const n = (await db.query(`select count(*)::int n from requests where email = $1`, [`qa-${label}-${RUN}@example.com`])).rows[0].n;
    assert.equal(n, 1, 'double click created exactly one request');
    const after = await stock('HOUSTON2-002');
    assert.equal(after.on_hand, before.on_hand, 'reservation does not touch physical stock');
    assert.equal(after.reserved, before.reserved + 3);
    const r = (await db.query(`select delivery_method, address_line, status from requests where folio = $1`, [folio])).rows[0];
    assert.deepEqual(r, { delivery_method: 'pickup', address_line: null, status: 'reserved' });
    await page.screenshot({ path: `${SHOTS}/e2e-${label}-confirmation.png` });
    // tracking with the private link
    await page.getByRole('link', { name: 'Track your request' }).click();
    await page.waitForSelector('.timeline li');
    assert.match(await page.locator('#out').textContent(), new RegExp(folio));
    assert.ok(!(await page.locator('#out').textContent()).includes(`qa-${label}-${RUN}@example.com`), 'no personal data on tracking page');
    await page.screenshot({ path: `${SHOTS}/e2e-${label}-track.png`, fullPage: true });
    // guessing a folio without the token reveals nothing
    await page.goto(`${BASE}/track/?f=${folio}&t=wrong`);
    await page.waitForFunction(() => !document.getElementById('out').textContent.includes('Loading'));
    assert.match(await page.locator('#out').textContent(), /could not find/);
  });

  await check(`${label}: availability changed → customer can correct before confirming`, async () => {
    await page.goto(BASE + '/');
    await page.waitForSelector('.card');
    const card = page.locator('.card', { hasText: 'Kiel' });
    await card.locator('input[type=number]').fill('5');
    await card.locator('[data-add]').click();
    // someone else takes almost everything meanwhile
    const s = (await db.query(`select s.id, s.on_hand, s.reserved from stock s join sample_skus k on k.id=s.sku_id where k.code='HOUSTON2-063'`)).rows[0];
    await db.query(`update stock set reserved = on_hand - 2 where id = $1`, [s.id]);   // test-only shortcut
    await page.goto(BASE + '/request/');
    await page.fill('#full_name', 'QA Change'); await page.fill('#email', `qa-change-${label}-${RUN}@example.com`); await page.fill('#phone', '713 555 0101');
    await page.fill('#address_line', '100 Main St'); await page.fill('#city', 'Houston'); await page.fill('#state', 'TX'); await page.fill('#zip_code', '77002');
    await page.waitForTimeout(3100);
    await page.locator('#submit').click();
    await page.waitForSelector('.sel-line.problem');
    assert.match(await page.locator('.sel-line.problem').textContent(), /Only 2 available/);
    assert.equal((await db.query(`select count(*)::int n from requests where email = $1`, [`qa-change-${label}-${RUN}@example.com`])).rows[0].n, 0, 'nothing stored');
    await page.locator('.sel-line.problem input[type=number]').fill('2');
    await page.locator('.sel-line.problem input[type=number]').dispatchEvent('change');
    await page.locator('#submit').click();
    await page.waitForSelector('.folio');
    await db.query(`update stock set reserved = $2 where id = $1`, [s.id, s.reserved + 2]);   // restore test data
  });
  if (errors.length) results.push(['FAIL', `${label}: JavaScript errors`, errors.join(' | ')]);
  await ctx.close();
}
await browser.close(); await db.end();
for (const r of results) console.log(r.join(' · '));
process.exit(results.some((r) => r[0] === 'FAIL') ? 1 : 0);
