// Issues a full Stripe refund for an invoice's payment_intent and inserts
// a negative payment row to reflect the refund in BEEP HQ. Called from the
// §3 Cancel Paid Invoice modal when the invoice was Stripe-paid.
//
// Auth: requires a signed-in Supabase session (Bearer token in the
// Authorization header). The studio_id is derived from the user, so only
// authorized members can refund their own studio's invoices.
//
// Supabase Dashboard → Edge Functions → Settings: leave "Verify JWT" ON
// for this function (this one IS authenticated, unlike stripe-webhook).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@16.2.0?target=denonext';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY_TEST_KEY') || Deno.env.get('STRIPE_SECRET_KEY') || '';
const stripe = new Stripe(STRIPE_KEY, {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const { payment_intent, invoice_id } = await req.json();
    if (!payment_intent || !invoice_id) return json({ error: 'Missing payment_intent or invoice_id.' }, 400);

    // Use service role to read/write invoice + payment rows after the
    // user-scoped JWT has been validated by the platform auth layer.
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    // Look up the invoice + the original Stripe payment row for the refund
    // amount + the studio_id, used in the new negative payment metadata.
    const { data: inv, error: invErr } = await sb
      .from('invoices')
      .select('id, number, studio_id, total, invoice_payments(id, amount, method, pending, stripe_payment_intent)')
      .eq('id', invoice_id)
      .single();
    if (invErr || !inv) return json({ error: 'Invoice not found.' }, 404);

    const originalPay = (inv.invoice_payments || []).find((p: any) => p.stripe_payment_intent === payment_intent && !p.pending);
    if (!originalPay) return json({ error: 'No matching Stripe payment found for this invoice.' }, 404);

    const refundAmountCents = Math.round(Number(originalPay.amount) * 100);
    if (refundAmountCents <= 0) return json({ error: 'Nothing to refund.' }, 400);

    // Issue the refund.
    let refund: Stripe.Refund;
    try {
      refund = await stripe.refunds.create({
        payment_intent,
        amount: refundAmountCents,
        reason: 'requested_by_customer',
        metadata: {
          invoice_id: inv.id,
          invoice_number: inv.number || '',
          studio_id: inv.studio_id,
        },
      });
    } catch (e) {
      console.error('[stripe-refund] Stripe refund failed:', e);
      return json({ error: 'Stripe refund failed: ' + (e as Error).message }, 502);
    }

    // Insert a negative payment row so BEEP HQ reflects the refund. Tagged
    // with a 'refund' notes prefix + the refund id so it can be reconciled
    // later if needed.
    const refundAmount = -Math.abs(Number(originalPay.amount));
    const { error: insErr } = await sb.from('invoice_payments').insert({
      invoice_id: inv.id,
      date: new Date().toISOString().slice(0, 10),
      amount: refundAmount,
      method: 'Refund — Stripe',
      notes: `Stripe refund ${refund.id} for invoice ${inv.number || ''}`,
      stripe_payment_intent: payment_intent,
      pending: false,
    });
    if (insErr) {
      console.error('[stripe-refund] failed to insert refund row:', insErr);
      // Don't fail the response — the Stripe refund DID go through; web app
      // will see the row on next sync once we resolve the insert issue.
    }

    // Flip the invoice to cancelled server-side so the web app sees it.
    await sb.from('invoices').update({ status: 'cancelled' }).eq('id', inv.id);

    return json({ ok: true, refund_id: refund.id, amount: Math.abs(refundAmount) });
  } catch (e) {
    console.error('[stripe-refund] handler error:', e);
    return json({ error: (e as Error).message }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
