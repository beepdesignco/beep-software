// Creates a Stripe Checkout Session for an invoice, given the payment_token.
// method: 'card' → 3.5% surcharge (or invoice.cc_fee_pct if set), card only
// method: 'ach'  → no surcharge, us_bank_account only
// Returns { url } for the client to redirect to.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@16.2.0?target=denonext';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, stripe-signature',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

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

    // ACH gets upgraded payment_method_options so the client links their
    // bank via Plaid (Stripe Financial Connections) — gives instant
    // verification instead of the 3-5 day micro-deposit dance, AND tends
    // to unlock higher per-transaction ACH limits because Stripe trusts
    // a Plaid-verified account more than a manually-entered one.
    //
    // verification_method 'automatic' = Plaid first, fall back to micro-
    // deposits if Plaid fails (rather than 'instant' which would block
    // the payment entirely if Plaid can't verify).
    //
    // permissions: 'payment_method' is required to charge. 'balances'
    // was previously added as an extra risk signal for larger ACH
    // limits, but it requires activating the Stripe Financial Connections
    // application (dashboard.stripe.com/financial-connections/application).
    // Removed 2026-07-13 after a client hit "You cannot request the
    // ['balances'] permissions... without first activating this product".
    // If Baylor wants higher ACH limits later, submit that application
    // and re-add 'balances' to the permissions list.
    const sessionParams: any = {
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
    };
    if (method === 'ach') {
      sessionParams.payment_method_options = {
        us_bank_account: {
          financial_connections: {
            permissions: ['payment_method'],
          },
          verification_method: 'automatic',
        },
      };
    }
    const session = await stripe.checkout.sessions.create(sessionParams);

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
