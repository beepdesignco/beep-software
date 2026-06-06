// Stripe webhook handler. Records invoice payments + manages invoice status
// across Stripe's payment lifecycle. Handles both instant (card) and
// asynchronous (ACH / bank debit) payment methods.
//
// Events handled:
//   checkout.session.completed           — customer submitted the payment
//                                          (cards: funds confirmed; ACH: pending)
//   checkout.session.async_payment_succeeded — ACH cleared, funds confirmed
//   checkout.session.async_payment_failed    — ACH bounced
//
// Supabase Dashboard → Edge Functions → Settings: disable "Verify JWT" for
// this function.

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
      await handleCheckoutSessionCompleted(sb, session);
    } else if (event.type === 'checkout.session.async_payment_succeeded') {
      const session = event.data.object as Stripe.Checkout.Session;
      await handleAsyncPaymentSucceeded(sb, session);
    } else if (event.type === 'checkout.session.async_payment_failed') {
      const session = event.data.object as Stripe.Checkout.Session;
      await handleAsyncPaymentFailed(sb, session);
    }

    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('[stripe-webhook] handler error:', e);
    return new Response((e as Error).message, { status: 500 });
  }
});

// Fires when the customer completes the Checkout flow. For cards this means
// the charge succeeded; for ACH this means the customer authorized the
// transfer but funds haven't actually moved yet.
//
//   session.payment_status === 'paid'   → funds confirmed → record + flip status
//   session.payment_status === 'unpaid' → ACH pending → record with pending note,
//                                         DON'T flip invoice status. Wait for the
//                                         async_payment_succeeded event when the
//                                         ACH actually clears (3-5 business days).
async function handleCheckoutSessionCompleted(sb: any, session: Stripe.Checkout.Session) {
  const md = session.metadata || {};
  const invoiceId = md.invoice_id;
  const method = md.method;
  const baseCents = parseInt(md.base_amount_cents || '0', 10);

  if (!invoiceId) {
    console.warn('[stripe-webhook] session missing invoice_id metadata');
    return;
  }

  const amount = baseCents / 100;
  const paymentIntent = session.payment_intent as string;
  const isPaid = session.payment_status === 'paid';

  // Idempotency — skip if we already recorded a row for this payment_intent.
  const { data: existing } = await sb
    .from('invoice_payments')
    .select('id')
    .eq('stripe_payment_intent', paymentIntent)
    .maybeSingle();
  if (existing) return;

  const methodLabel = method === 'card' ? 'Credit Card' : 'ACH';
  const notes = isPaid
    ? `Stripe ${session.id}`
    : `Stripe ${session.id} — ACH pending settlement (typically 3-5 business days)`;

  // Pending flag (phase0_35): true when ACH submitted but not yet settled.
  // The sales tax report + invoice Paid/Outstanding totals exclude pending=true
  // rows so cash-basis monthly reporting only counts funds actually received.
  const { error } = await sb.from('invoice_payments').insert({
    invoice_id: invoiceId,
    date: new Date().toISOString().slice(0, 10),
    amount,
    method: methodLabel,
    notes,
    stripe_payment_intent: paymentIntent,
    pending: !isPaid,
  });
  if (error) {
    console.error('[stripe-webhook] insert payment failed:', error);
    throw new Error(error.message);
  }

  // Only flip the invoice status to paid/partial if funds are actually here.
  // For ACH the async_payment_succeeded handler will recompute status when
  // the funds settle. Leaving the invoice at 'sent' in the meantime keeps
  // PM downstream transitions (item → ready_for_ordering, expense → resolved)
  // from firing prematurely on funds that haven't actually cleared.
  if (isPaid) {
    await recomputeInvoiceStatus(sb, invoiceId);
  }
}

// Fires when an asynchronous payment (ACH) finally clears. The payment row
// was already inserted at checkout.session.completed time with a 'pending'
// note — update its note and now flip the invoice status. If for some
// reason the row doesn't exist (missed completed event), insert it.
async function handleAsyncPaymentSucceeded(sb: any, session: Stripe.Checkout.Session) {
  const md = session.metadata || {};
  const invoiceId = md.invoice_id;
  const method = md.method;
  const baseCents = parseInt(md.base_amount_cents || '0', 10);
  if (!invoiceId) {
    console.warn('[stripe-webhook] async_succeeded: missing invoice_id metadata');
    return;
  }
  const paymentIntent = session.payment_intent as string;
  const methodLabel = method === 'card' ? 'Credit Card' : 'ACH';
  const cleanNote = `Stripe ${session.id}`;

  const { data: existing } = await sb
    .from('invoice_payments')
    .select('id')
    .eq('stripe_payment_intent', paymentIntent)
    .maybeSingle();

  // On settlement: clear pending + bump the date to today (the actual
  // settlement date), so cash-basis tax reporting lands the receipt in
  // the correct month — not the submission month.
  if (existing) {
    const { error } = await sb.from('invoice_payments')
      .update({ notes: cleanNote, pending: false, date: new Date().toISOString().slice(0, 10) })
      .eq('id', existing.id);
    if (error) console.warn('[stripe-webhook] async_succeeded update failed:', error);
  } else {
    // Missed the completed event somehow — insert the row now (as cleared).
    const amount = baseCents / 100;
    const { error } = await sb.from('invoice_payments').insert({
      invoice_id: invoiceId,
      date: new Date().toISOString().slice(0, 10),
      amount,
      method: methodLabel,
      notes: cleanNote,
      stripe_payment_intent: paymentIntent,
      pending: false,
    });
    if (error) {
      console.error('[stripe-webhook] async_succeeded insert failed:', error);
      throw new Error(error.message);
    }
  }

  // Funds have actually cleared — recompute status now (will flip to paid).
  await recomputeInvoiceStatus(sb, invoiceId);
}

// Fires when an asynchronous payment (ACH) fails to clear (NSF, account
// closed, dispute, etc.). Remove the pending payment row so the invoice
// stops counting it. Invoice falls back to 'sent' via recomputeInvoiceStatus.
async function handleAsyncPaymentFailed(sb: any, session: Stripe.Checkout.Session) {
  const md = session.metadata || {};
  const invoiceId = md.invoice_id;
  if (!invoiceId) {
    console.warn('[stripe-webhook] async_failed: missing invoice_id metadata');
    return;
  }
  const paymentIntent = session.payment_intent as string;
  const { error: delErr } = await sb.from('invoice_payments')
    .delete()
    .eq('stripe_payment_intent', paymentIntent);
  if (delErr) console.warn('[stripe-webhook] async_failed delete failed:', delErr);
  await recomputeInvoiceStatus(sb, invoiceId);
}

// Sum the invoice's payments, compare to total, set status accordingly.
async function recomputeInvoiceStatus(sb: any, invoiceId: string) {
  const { data: inv } = await sb
    .from('invoices').select('id, total, status, invoice_payments(amount)')
    .eq('id', invoiceId).single();
  if (!inv) return;
  const totalPaid = (inv.invoice_payments || []).reduce((s: number, p: any) => s + Number(p.amount || 0), 0);
  let newStatus = inv.status;
  if (totalPaid <= 0.001) newStatus = 'sent';
  else if (totalPaid + 0.01 < Number(inv.total || 0)) newStatus = 'partial';
  else newStatus = 'paid';
  if (newStatus !== inv.status) {
    await sb.from('invoices').update({ status: newStatus }).eq('id', invoiceId);
  }
}
