// Processes the notifications outbox. Invoked every minute by pg_cron (supabase/deploy/cron.sql),
// so emails go out even when nobody has the platform open.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, WORKER_SECRET, RESEND_API_KEY, MAIL_FROM, MAIL_REPLY_TO,
//          PUBLIC_SITE_URL, MAIL_MODE ("test" | "production"), MAIL_TEST_RECIPIENTS (comma separated)
import { render } from '../_shared/templates.ts';

const env = (k: string) => Deno.env.get(k) || '';
const rpc = (fn: string, args: unknown) => fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/${fn}`, {
  method: 'POST', body: JSON.stringify(args),
  headers: { apikey: env('SUPABASE_SERVICE_ROLE_KEY'), Authorization: `Bearer ${env('SUPABASE_SERVICE_ROLE_KEY')}`, 'content-type': 'application/json' },
});

Deno.serve(async (req) => {
  if (req.headers.get('x-worker-secret') !== env('WORKER_SECRET') || !env('WORKER_SECRET')) return new Response('forbidden', { status: 403 });
  const claimed = await rpc('notifications_claim', { p_batch: 25 });
  if (!claimed.ok) return new Response(await claimed.text(), { status: 500 });
  const items: any[] = await claimed.json();
  const testMode = env('MAIL_MODE') !== 'production';
  const testList = env('MAIL_TEST_RECIPIENTS').split(',').map((s) => s.trim()).filter(Boolean);
  let sent = 0, failed = 0;
  for (const raw of items) {
    const n = raw.notifications_claim ?? raw;
    try {
      // the tracking token is computed by the database from its own secret (never stored)
      const token = n.audience === 'customer' && n.request?.source === 'web'
        ? await rpc('notification_track_token', { p_folio: n.request.folio }).then((r) => r.ok ? r.json() : undefined) : undefined;
      const mail = render(n, { siteUrl: env('PUBLIC_SITE_URL'), trackToken: token });
      // TEST mode: real recipients are never contacted; the message goes to the authorized test inbox(es)
      const to = testMode ? testList : [n.recipient];
      if (!to.length) throw new Error('MAIL_MODE=test and MAIL_TEST_RECIPIENTS is empty');
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'content-type': 'application/json', 'Idempotency-Key': n.dedupe_key.slice(0, 256) },
        body: JSON.stringify({ from: env('MAIL_FROM'), reply_to: env('MAIL_REPLY_TO') || undefined, to,
          subject: (testMode ? `[TEST → ${n.recipient}] ` : '') + mail.subject, html: mail.html, text: mail.text,
          tags: [{ name: 'event', value: n.event }] }),
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(`provider ${r.status}: ${JSON.stringify(body).slice(0, 300)}`);
      await rpc('notifications_result', { p_id: n.id, p_ok: true, p_provider_id: body.id ?? null });   // accepted ≠ delivered
      sent++;
    } catch (e) {
      await rpc('notifications_result', { p_id: n.id, p_ok: false, p_error: String((e as Error).message || e) });
      failed++;
    }
  }
  return new Response(JSON.stringify({ claimed: items.length, accepted: sent, failed }), { headers: { 'content-type': 'application/json' } });
});
