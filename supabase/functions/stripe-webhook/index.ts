// Stripe webhook handler. Verifies signature, processes
// checkout.session.completed events and inserts an invoice_payments row.
// Supabase Dashboard → Edge Functions → Settings: disable "Verify JWT" for this function.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@16.2.0?target=denonext';

const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY_TEST_KEY') || Deno.env.get('STRIPE_SECRET_KEY') || '';
const stripe = new Stripe(STRIPE_KEY, {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
});

// Webhook secrets differ between test mode (test webhook endpoint) and live.
const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET_TEST') || Deno.env.get('STRIPE_WEBHOOK_SECRET') || '';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const sig = req.headers.get('stripe-signature');
  if (!sig) return new Response('Missing signature', { status: 400 });

  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret);
  } catch (err) {
    console.error('[stripe-webhook] signature verification failed:', err);
    return new Response(`Signature error: ${(err as Error).message}`, { status: 400 });
  }

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  try {
    if (event.type === 'checkout.session.completed') {
      const session = event.data.object as Stripe.Checkout.Session;
      const md = session.metadata || {};
      const invoiceId = md.invoice_id;
      const method = md.method;
      const baseCents = parseInt(md.base_amount_cents || '0', 10);

      if (!invoiceId) {
        console.warn('[stripe-webhook] session missing invoice_id metadata');
        return new Response('ok', { status: 200 });
      }

      // Record payment. Use the BASE amount (not the surcharged total) so BEEP HQ's
      // reporting reflects true revenue; the card fee is a pass-through cost.
      const amount = baseCents / 100;

      // Skip if we already recorded this session
      const { data: existing } = await sb
        .from('invoice_payments')
        .select('id')
        .eq('stripe_payment_intent', session.payment_intent as string)
        .maybeSingle();
      if (existing) return new Response('ok', { status: 200 });

      const { error } = await sb.from('invoice_payments').insert({
        invoice_id: invoiceId,
        date: new Date().toISOString().slice(0, 10),
        amount,
        method: method === 'card' ? 'Credit Card' : 'ACH',
        notes: `Stripe ${session.id}`,
        stripe_payment_intent: session.payment_intent as string,
      });
      if (error) {
        console.error('[stripe-webhook] insert payment failed:', error);
        return new Response(error.message, { status: 500 });
      }

      // Recompute invoice status in SQL: sum payments, compare to total
      const { data: inv } = await sb
        .from('invoices').select('id, total, status, invoice_payments(amount)')
        .eq('id', invoiceId).single();
      if (inv) {
        const totalPaid = (inv.invoice_payments || []).reduce((s: number, p: any) => s + Number(p.amount || 0), 0);
        let newStatus = inv.status;
        if (totalPaid <= 0.001) newStatus = 'sent';
        else if (totalPaid + 0.01 < Number(inv.total || 0)) newStatus = 'partial';
        else newStatus = 'paid';
        if (newStatus !== inv.status) {
          await sb.from('invoices').update({ status: newStatus }).eq('id', invoiceId);
        }
      }
    }

    // Other events we might care about later: payment_intent.succeeded (for ACH which
    // takes days to clear), payment_intent.payment_failed, etc.

    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('[stripe-webhook] handler error:', e);
    return new Response((e as Error).message, { status: 500 });
  }
});
