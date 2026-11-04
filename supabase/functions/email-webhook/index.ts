// Delivery events from the email provider (Resend → Svix-signed webhook): delivered / bounced / complained.
// Secret: RESEND_WEBHOOK_SECRET ("whsec_…").
const env = (k: string) => Deno.env.get(k) || '';
const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function verify(req: Request, body: string): Promise<boolean> {
  const id = req.headers.get('svix-id'), ts = req.headers.get('svix-timestamp'), sig = req.headers.get('svix-signature');
  if (!id || !ts || !sig || Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const key = await crypto.subtle.importKey('raw', b64(env('RESEND_WEBHOOK_SECRET').replace(/^whsec_/, '')), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${ts}.${body}`)))));
  return sig.split(' ').some((s) => s.split(',')[1] === mac);
}

Deno.serve(async (req) => {
  const body = await req.text();
  if (!(await verify(req, body))) return new Response('invalid signature', { status: 401 });
  const ev = JSON.parse(body);
  const map: Record<string, string> = { 'email.delivered': 'delivered', 'email.bounced': 'bounced', 'email.complained': 'complained' };
  if (map[ev.type] && ev.data?.email_id) {
    await fetch(`${env('SUPABASE_URL')}/rest/v1/rpc/notifications_provider_event`, {
      method: 'POST',
      headers: { apikey: env('SUPABASE_SERVICE_ROLE_KEY'), Authorization: `Bearer ${env('SUPABASE_SERVICE_ROLE_KEY')}`, 'content-type': 'application/json' },
      body: JSON.stringify({ p_provider_id: ev.data.email_id, p_event: map[ev.type], p_detail: JSON.stringify(ev.data).slice(0, 900) }),
    });
  }
  return new Response('ok');
});
