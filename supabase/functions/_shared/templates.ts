// Email templates. Customer emails are in English; internal emails in Spanish.
// Never include shipping costs or internal notes in customer emails.

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
const CARRIER_URL: Record<string, (t: string) => string> = {
  UPS: (t) => `https://www.ups.com/track?tracknum=${encodeURIComponent(t)}`,
  FEDEX: (t) => `https://www.fedex.com/fedextrack/?trknbr=${encodeURIComponent(t)}`,
  USPS: (t) => `https://tools.usps.com/go/TrackConfirmAction?tLabels=${encodeURIComponent(t)}`,
  DHL: (t) => `https://www.dhl.com/us-en/home/tracking.html?tracking-id=${encodeURIComponent(t)}`,
};

const CUSTOMER: Record<string, { subject: string; lead: string }> = {
  request_confirmed: { subject: 'We received your sample request', lead: 'Thank you. We received your sample request and reserved the samples you selected.' },
  samples_prepared: { subject: 'Your samples are prepared', lead: 'Your samples have been prepared and packed.' },
  tracking_registered: { subject: 'Tracking number for your samples', lead: 'A shipping label was created for your samples.' },
  shipped: { subject: 'Your samples have shipped', lead: 'Your samples were handed to the carrier.' },
  ready_for_pickup: { subject: 'Your samples are ready for pickup', lead: 'Your samples are ready for pickup at our warehouse.' },
  delivered: { subject: 'Your samples were delivered', lead: 'The carrier reports your samples as delivered.' },
  collected: { subject: 'Your samples were picked up', lead: 'Your samples were picked up. Thank you.' },
  cancelled: { subject: 'Your sample request was cancelled', lead: 'Your sample request was cancelled. If this is unexpected, please reply to this email.' },
};
const INTERNAL: Record<string, string> = {
  request_confirmed: 'Nueva solicitud de muestras', samples_prepared: 'Muestras preparadas', tracking_registered: 'Guía registrada',
  shipped: 'Pedido enviado', ready_for_pickup: 'Disponible para recoger', delivered: 'Pedido entregado', collected: 'Pedido recogido',
  cancelled: 'Solicitud cancelada', incident: 'Incidencia registrada', invoice_document: 'Documento de facturación disponible',
};

function shell(title: string, body: string) {
  return `<!doctype html><html><body style="margin:0;background:#f4f4f2;font-family:Montserrat,Arial,sans-serif;color:#191d20">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border:1px solid #e3e1dc">
<tr><td style="background:#191d20;color:#ffffff;padding:20px 28px;font-size:18px;letter-spacing:.18em;font-weight:600">CESANTONI</td></tr>
<tr><td style="padding:28px"><h1 style="font-size:20px;margin:0 0 16px">${esc(title)}</h1>${body}</td></tr>
<tr><td style="padding:16px 28px;border-top:1px solid #e3e1dc;font-size:12px;color:#6b6b6b">CESANTONI Samples · This message was sent automatically.</td></tr>
</table></td></tr></table></body></html>`;
}

export function render(n: any, opts: { siteUrl: string; trackToken?: string }) {
  const r = n.request || {};
  const lines = (r.lines || []).map((l: any) => `<tr><td style="padding:6px 0;border-bottom:1px solid #eee">${esc(l.description)}</td><td align="right" style="padding:6px 0;border-bottom:1px solid #eee">${esc(l.quantity)}</td></tr>`).join('');
  const table = lines ? `<table width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;margin:16px 0">${lines}</table>` : '';
  const ship = (r.shipments || [])[0] || (n.payload?.tracking_no ? { carrier: n.payload.carrier, tracking_no: n.payload.tracking_no } : null);
  if (n.audience === 'customer') {
    const t = CUSTOMER[n.event];
    if (!t) throw new Error(`no customer template for ${n.event}`);
    const track = opts.trackToken ? `${opts.siteUrl.replace(/\/$/, '')}/track/?f=${encodeURIComponent(r.folio)}&t=${encodeURIComponent(opts.trackToken)}` : null;
    const carrier = ship && ['tracking_registered', 'shipped', 'delivered'].includes(n.event)
      ? `<p style="font-size:14px">Carrier: <b>${esc(ship.carrier)}</b><br>Tracking number: <b>${CARRIER_URL[ship.carrier] ? `<a href="${CARRIER_URL[ship.carrier](ship.tracking_no)}">${esc(ship.tracking_no)}</a>` : esc(ship.tracking_no)}</b></p>` : '';
    const html = shell(t.subject, `<p style="font-size:14px">Hello ${esc(r.full_name)},</p><p style="font-size:14px">${esc(t.lead)}</p>
<p style="font-size:14px">Request number: <b>${esc(r.folio)}</b></p>${carrier}${table}
${track ? `<p><a href="${track}" style="display:inline-block;background:#191d20;color:#fff;padding:12px 20px;text-decoration:none;font-size:14px">Track your request</a></p>` : ''}`);
    const text = `Hello ${r.full_name},\n\n${t.lead}\n\nRequest number: ${r.folio}\n${ship ? `Carrier: ${ship.carrier} · Tracking: ${ship.tracking_no}\n` : ''}${(r.lines || []).map((l: any) => `- ${l.description} × ${l.quantity}`).join('\n')}\n${track ? `\nTrack your request: ${track}\n` : ''}`;
    return { subject: `${t.subject} · ${r.folio}`, html, text };
  }
  const title = INTERNAL[n.event] || n.event;
  const extra = n.payload?.description || n.payload?.reason ? `<p style="font-size:14px">${esc(n.payload.description || n.payload.reason)}</p>` : '';
  const html = shell(`${title} · ${r.folio}`, `<p style="font-size:14px">Folio <b>${esc(r.folio)}</b> · ${esc(r.full_name)}${r.company ? ' · ' + esc(r.company) : ''}<br>
Entrega: ${r.delivery_method === 'pickup' ? 'Recolección en almacén' : 'Paquetería'} · Estatus: ${esc(r.status)}</p>${extra}${table}
<p><a href="${opts.siteUrl.replace(/\/$/, '')}/admin/#/requests/${encodeURIComponent(r.folio)}">Abrir en la plataforma</a></p>`);
  return { subject: `${title} · ${r.folio}`, html, text: `${title} · ${r.folio}\n${opts.siteUrl}/admin/` };
}
