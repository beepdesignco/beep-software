// Public endpoint — no auth required. Given an invoice payment_token,
// returns the data needed to render the client-facing payment page.
// Only exposes fields safe for the client to see.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, stripe-signature',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get('t');
    if (!token) return json({ error: 'Missing token' }, 400);

    // Use service role so RLS doesn't gate this lookup; the token itself is the authorization.
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: inv, error } = await sb
      .from('invoices')
      .select('id, number, type, status, phase, sent_date, due_date, notes, note_selections, subtotal, freight, freight_taxable, discount, discount_type, discount_value, cc_fee_pct, cc_fee, tax_rate, tax, total, project_id, client_id, studio_id, watermark_mode, invoice_line_items(id, name, description, qty, price, taxable, sort_order), invoice_payments(id, date, amount, method)')
      .eq('payment_token', token)
      .is('deleted_at', null)
      .single();

    if (error || !inv) return json({ error: 'Invoice not found.' }, 404);
    if (inv.status === 'cancelled') return json({ error: 'This invoice has been cancelled.' }, 410);

    // Pull studio info (name, address, email, website, check_mailing_address, wire_instructions, logo)
    const { data: studio } = await sb
      .from('studios')
      .select('id, name, studio_info')
      .eq('id', inv.studio_id)
      .single();

    // If a logo is attached, sign a URL for it (valid 1 hour)
    let logoUrl = null;
    const studioInfo = (studio?.studio_info as any) || {};
    const logoPath = studioInfo.logo?.storagePath;
    if (logoPath) {
      const { data: signed } = await sb.storage.from('files').createSignedUrl(logoPath, 3600);
      logoUrl = signed?.signedUrl || null;
    }

    // Resolve watermark based on invoice.watermark_mode + studio defaults
    let watermarkUrl = null;
    let watermarkOpacity = (studioInfo.watermarkOpacity || 5) / 100;
    const mode = (inv as any).watermark_mode || 'default';
    const on = mode === 'on' || (mode === 'default' && !!studioInfo.watermarkDefaultOn);
    if (on) {
      const list = studioInfo.watermarks || [];
      const wm = list.find((w: any) => w.id === studioInfo.defaultWatermarkId) || list[0];
      if (wm?.storagePath) {
        const { data: signedWm } = await sb.storage.from('files').createSignedUrl(wm.storagePath, 3600);
        watermarkUrl = signedWm?.signedUrl || null;
      }
    }

    const { data: project } = inv.project_id
      ? await sb.from('projects').select('id, name, street, city, state, zip').eq('id', inv.project_id).maybeSingle()
      : { data: null };

    const { data: client } = inv.client_id
      ? await sb.from('clients').select('id, name, email, phone, address').eq('id', inv.client_id).maybeSingle()
      : { data: null };

    const amountPaid = (inv.invoice_payments || []).reduce((s: number, p: any) => s + Number(p.amount || 0), 0);
    const amountDue = Math.max(0, Number(inv.total || 0) - amountPaid);

    // Compose display notes from studio preset library + this invoice's selections + free-form.
    const presets: any[] = studioInfo?.defaultInvoiceNotes || [];
    const selected: string[] = Array.isArray((inv as any).note_selections) ? (inv as any).note_selections : [];
    const presetParts = selected.map(id => presets.find(p => p.id === id)?.body).filter(Boolean);
    const extra = String(inv.notes || '').trim();
    if (extra) presetParts.push(extra);
    const composedNotes = presetParts.join('\n\n');

    return json({
      invoice: {
        id: inv.id,
        number: inv.number,
        status: inv.status,
        sent_date: inv.sent_date,
        due_date: inv.due_date,
        notes: composedNotes,
        subtotal: Number(inv.subtotal || 0),
        freight: Number(inv.freight || 0),
        discount: Number(inv.discount || 0),
        tax_rate: Number(inv.tax_rate || 0),
        tax: Number(inv.tax || 0),
        cc_fee_pct: Number(inv.cc_fee_pct || 3.5),
        total: Number(inv.total || 0),
        amount_paid: amountPaid,
        amount_due: amountDue,
        line_items: (inv.invoice_line_items || [])
          .slice()
          .sort((a: any, b: any) => (a.sort_order || 0) - (b.sort_order || 0))
          .map((l: any) => ({
            name: l.name,
            description: l.description,
            qty: Number(l.qty || 1),
            price: Number(l.price || 0),
            taxable: !!l.taxable,
          })),
        payments: (inv.invoice_payments || []).map((p: any) => ({
          date: p.date, amount: Number(p.amount || 0), method: p.method,
        })),
      },
      studio: {
        name: studio?.name || 'Studio',
        info: studio?.studio_info || {},
        logo_url: logoUrl,
        watermark_url: watermarkUrl,
        watermark_opacity: watermarkOpacity,
      },
      project: project ? {
        name: project.name,
        address: [project.street, [project.city, project.state].filter(Boolean).join(', '), project.zip].filter(Boolean).join('\n'),
      } : null,
      client: client ? { name: client.name, email: client.email, phone: client.phone } : null,
    });
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
