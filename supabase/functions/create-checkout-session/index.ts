// Creates a Stripe Checkout Session for an invoice, given the payment_token.
// method: 'card' → 3.5% surcharge (or invoice.cc_fee_pct if set), card only
// method: 'ach'  → no surcharge, us_bank_account only
// Returns { url } for the client to redirect to.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@16.2.0?target=denonext';
import { corsHeaders } from '../_shared/cors.ts';

// Prefer the test key during development; falls back to STRIPE_SECRET_KEY (live) in production.
// To switch to live: delete STRIPE_SECRET_KEY_TEST_KEY from Supabase secrets (or rename it).
const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY_TEST_KEY') || Deno.env.get('STRIPE_SECRET_KEY') || '';
const stripe = new Stripe(STRIPE_KEY, {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const { token, method, origin } = await req.json();
    if (!token || !method) return json({ error: 'Missing token or method.' }, 400);
    if (!['card', 'ach'].includes(method)) return json({ error: 'Invalid method.' }, 400);

    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    const { data: inv, error } = await sb
      .from('invoices')
      .select('id, number, total, cc_fee_pct, studio_id, client_id, invoice_payments(amount)')
      .eq('payment_token', token)
      .is('deleted_at', null)
      .single();
    if (error || !inv) return json({ error: 'Invoice not found.' }, 404);

    const paid = (inv.invoice_payments || []).reduce((s: number, p: any) => s + Number(p.amount || 0), 0);
    const due = Math.max(0, Number(inv.total) - paid);
    if (due <= 0) return json({ error: 'Invoice already paid.' }, 400);

    const { data: client } = inv.client_id
      ? await sb.from('clients').select('email, name').eq('id', inv.client_id).maybeSingle()
      : { data: null };

    // Card adds surcharge; ACH does not.
    const ccFeePct = Number(inv.cc_fee_pct || 3.5);
    const chargeAmount = method === 'card' ? Math.round(due * (1 + ccFeePct / 100) * 100) : Math.round(due * 100);
    const feeAmount = method === 'card' ? Math.round(due * (ccFeePct / 100) * 100) : 0;

    const baseUrl = origin || 'https://hq.beepdesign.co';

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: method === 'card' ? ['card'] : ['us_bank_account'],
      customer_email: client?.email || undefined,
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: `Invoice ${inv.number}`,
              description: method === 'card'
                ? `$${(due).toFixed(2)} + ${ccFeePct}% card fee ($${(feeAmount/100).toFixed(2)})`
                : `ACH bank transfer — no fee`,
            },
            unit_amount: chargeAmount,
          },
          quantity: 1,
        },
      ],
      metadata: {
        invoice_id: inv.id,
        invoice_number: inv.number,
        studio_id: inv.studio_id,
        method,
        base_amount_cents: String(Math.round(due * 100)),
        fee_amount_cents: String(feeAmount),
      },
      success_url: `${baseUrl}/pay/?t=${encodeURIComponent(token)}&status=success`,
      cancel_url:  `${baseUrl}/pay/?t=${encodeURIComponent(token)}&status=cancel`,
    });

    await sb.from('invoices').update({ stripe_checkout_session_id: session.id }).eq('id', inv.id);

    return json({ url: session.url });
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
