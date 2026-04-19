// send-email — wraps Resend API, used for invoice sends + (later) reminders.
// Requires RESEND_API_KEY set as an Edge Function secret.
// Call with authenticated user's JWT so we can verify they belong to the studio they're acting on.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  try {
    const auth = req.headers.get('authorization') || '';
    const jwt = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!jwt) return json({ error: 'Missing auth' }, 401);

    const { invoice_id, type, to, subject, html, text, reply_to, from_name, from_email } = await req.json();

    if (!invoice_id || !type || !to || !subject || !html) {
      return json({ error: 'Missing required fields (invoice_id, type, to, subject, html).' }, 400);
    }

    // Auth: confirm caller can send invoices for this studio via RLS-enforced select on the invoice
    const sbUser = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data: inv, error: invErr } = await sbUser
      .from('invoices').select('id, studio_id, number').eq('id', invoice_id).maybeSingle();
    if (invErr) return json({ error: 'Auth check failed: ' + invErr.message }, 403);
    if (!inv) return json({ error: 'Invoice not found or forbidden.' }, 404);

    // Send via Resend
    const fromAddr = from_email || 'hello@beepdesign.co';
    const fromDisplay = from_name ? `${from_name} <${fromAddr}>` : fromAddr;
    const payload: any = {
      from: fromDisplay,
      to: Array.isArray(to) ? to : [to],
      subject,
      html,
    };
    if (text) payload.text = text;
    if (reply_to) payload.reply_to = reply_to;

    const resp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    const body = await resp.json();
    if (!resp.ok) {
      console.error('[resend] send failed:', body);
      return json({ error: body?.message || 'Resend failed', details: body }, 502);
    }

    // Log the send using service-role so RLS doesn't block (caller already passed auth above)
    const sbAdmin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: userRec } = await sbUser.auth.getUser();
    await sbAdmin.from('invoice_sends').insert({
      studio_id: inv.studio_id,
      invoice_id: inv.id,
      type,
      recipient_email: Array.isArray(to) ? to[0] : to,
      subject,
      resend_message_id: body?.id || null,
      sent_by_user_id: userRec?.user?.id || null,
    });

    return json({ success: true, resend_id: body?.id || null });
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
