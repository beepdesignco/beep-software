// run-invoice-reminders — scheduled daily via pg_cron.
// For every sent/partial invoice with amount_due > 0, evaluate its effective
// reminder schedule against today and send any rules whose date matches.
// Dedup via invoice_sends.rule_key so a rule fires at most once per invoice.
//
// Invoked by pg_cron with no auth — uses service role internally.
// Also callable manually (POST /run-invoice-reminders) for testing; pass
// ?dry=1 to skip actual send + logging and return what would have fired.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const PUBLIC_APP_URL = Deno.env.get('PUBLIC_APP_URL') || 'https://hq.beepdesign.co';
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const DEFAULT_FROM   = Deno.env.get('DEFAULT_FROM_EMAIL') || 'hello@beepdesign.co';

// Must stay in sync with DEFAULT_EMAIL_TEMPLATES in index.html.
// We duplicate here instead of querying — these are app-level defaults, not user data.
const DEFAULT_EMAIL_TEMPLATES: Record<string, { name: string; subject: string; body: string }> = {
  'builtin-new-invoice': {
    name: 'New invoice',
    subject: 'Invoice {invoice.number} — {project.name}',
    body: 'Hi {client.firstName},\n\nHere is invoice {invoice.number} for {project.name}, totaling {invoice.total}. It is due on {invoice.dueDate}.\n\nLet me know if you have any questions.\n\nThank you,\n{me.name}',
  },
  'builtin-monthly': {
    name: 'Monthly charges',
    subject: 'Monthly charges — {invoice.sentDate}',
    body: 'Hi {client.firstName},\n\nAttached is your monthly design-hours invoice for {project.name} ({invoice.number}), totaling {invoice.total} due {invoice.dueDate}.\n\nThank you,\n{me.name}',
  },
  'builtin-phase': {
    name: 'Phase invoice',
    subject: 'Invoice {invoice.number} — {project.name} · {invoice.phase}',
    body: 'Hi {client.firstName},\n\nHere is the {invoice.phase} invoice for {project.name} ({invoice.number}), totaling {invoice.total}. Due {invoice.dueDate}.\n\nLet me know if anything needs adjusting.\n\nThank you,\n{me.name}',
  },
  'builtin-revised': {
    name: 'Revised invoice',
    subject: 'Revised invoice {invoice.number}',
    body: 'Hi {client.firstName},\n\nQuick update — I have revised invoice {invoice.number} for {project.name}. The new total is {invoice.total}, due {invoice.dueDate}.\n\nThank you,\n{me.name}',
  },
  'builtin-reminder': {
    name: 'Friendly reminder',
    subject: 'Friendly reminder: invoice {invoice.number}',
    body: 'Hi {client.firstName},\n\nJust a quick reminder that invoice {invoice.number} for {project.name} is due {invoice.dueDate}. The balance is {invoice.total}.\n\nThanks so much,\n{me.name}',
  },
  'builtin-due-today': {
    name: 'Due today',
    subject: 'Invoice {invoice.number} — due today',
    body: 'Hi {client.firstName},\n\nJust a reminder that invoice {invoice.number} for {project.name} is due today. The balance is {invoice.total}.\n\nThank you,\n{me.name}',
  },
};

const BUILTIN_REMINDER_DEFAULTS: Record<string, any[]> = {
  phased:     [{ days: 3, when: 'after', templateId: 'builtin-reminder' }, { days: 10, when: 'after', templateId: 'builtin-reminder' }],
  monthly:    [{ days: 3, when: 'after', templateId: 'builtin-reminder' }, { days: 10, when: 'after', templateId: 'builtin-reminder' }],
  standalone: [{ days: 3, when: 'after', templateId: 'builtin-reminder' }, { days: 10, when: 'after', templateId: 'builtin-reminder' }],
  design_fee: [{ days: 3, when: 'after', templateId: 'builtin-reminder' }, { days: 10, when: 'after', templateId: 'builtin-reminder' }],
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });

  const url = new URL(req.url);
  const dryRun = url.searchParams.get('dry') === '1';
  const onlyInvoiceId = url.searchParams.get('invoice_id'); // for single-invoice testing

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  try {
    // Fetch all active invoices with status sent/partial, plus their line items, payments,
    // studio (for info + reminderDefaults + logo path), project, client.
    let q = sb.from('invoices').select(`
      id, number, type, status, phase, sent_date, due_date, total, studio_id,
      client_id, project_id, payment_token, reminder_override,
      invoice_payments(amount),
      studios:studio_id(id, name, studio_info),
      clients:client_id(id, name, email),
      projects:project_id(id, name)
    `).in('status', ['sent', 'partial']).is('deleted_at', null);
    if (onlyInvoiceId) q = q.eq('id', onlyInvoiceId);
    const { data: invoices, error: invErr } = await q;
    if (invErr) throw invErr;

    const today = todayISO();
    const fired: Array<{ invoice_id: string; rule_key: string; to: string; status: string; error?: string }> = [];

    for (const inv of (invoices || [])) {
      const amountPaid = (inv.invoice_payments || []).reduce((s: number, p: any) => s + Number(p.amount || 0), 0);
      const amountDue = Number(inv.total || 0) - amountPaid;
      if (amountDue <= 0.01) continue;
      if (!inv.due_date) continue;

      const studio: any = Array.isArray(inv.studios) ? inv.studios[0] : inv.studios;
      const client: any = Array.isArray(inv.clients) ? inv.clients[0] : inv.clients;
      const project: any = Array.isArray(inv.projects) ? inv.projects[0] : inv.projects;
      const studioInfo = studio?.studio_info || {};

      const schedule = getEffectiveSchedule(inv, studioInfo);
      const matching = schedule.filter(r => ruleFiresOn(r, inv.due_date, today));
      if (matching.length === 0) continue;

      // Fetch already-fired rule_keys for this invoice in one go
      const { data: alreadySent } = await sb
        .from('invoice_sends')
        .select('rule_key')
        .eq('invoice_id', inv.id)
        .not('rule_key', 'is', null);
      const sentKeys = new Set((alreadySent || []).map((s: any) => s.rule_key));

      const toEmail = client?.email;
      if (!toEmail) {
        for (const rule of matching) {
          fired.push({ invoice_id: inv.id, rule_key: ruleKey(rule), to: '', status: 'skipped-no-email' });
        }
        continue;
      }

      for (const rule of matching) {
        const key = ruleKey(rule);
        if (sentKeys.has(key)) { fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'skipped-already-sent' }); continue; }

        const tpl = resolveTemplate(rule.templateId, studioInfo);
        if (!tpl) { fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'skipped-no-template' }); continue; }

        const ctx = buildTemplateContext(inv, studioInfo, studio, client, project);
        const subject = fillTemplate(tpl.subject, ctx);
        const message = fillTemplate(tpl.body, ctx);
        const payUrl  = `${PUBLIC_APP_URL}/pay/?t=${encodeURIComponent(inv.payment_token || '')}`;
        const logoUrl = await resolveLogoDataUrl(sb, studioInfo);
        const html    = buildInvoiceEmailHtml({ inv, studio, studioInfo, client, project, message, payUrl, logoUrl });
        const text    = buildInvoiceEmailText({ inv, studioInfo, payUrl, message });

        if (dryRun) {
          fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'dry-run' });
          continue;
        }

        try {
          const resp = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({
              from: `${studio?.name || 'Beep Design'} <${DEFAULT_FROM}>`,
              to: [toEmail],
              subject,
              html,
              text,
              reply_to: studioInfo.email || undefined,
            }),
          });
          const body = await resp.json();
          if (!resp.ok) {
            console.error('[reminders] resend fail', inv.number, key, body);
            fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'send-failed', error: body?.message || 'resend error' });
            continue;
          }
          // Log with rule_key so we dedup next run
          const { error: logErr } = await sb.from('invoice_sends').insert({
            studio_id: inv.studio_id,
            invoice_id: inv.id,
            type: 'reminder',
            recipient_email: toEmail,
            subject,
            resend_message_id: body?.id || null,
            rule_key: key,
          });
          if (logErr) {
            // If the unique index rejects a duplicate, another run already logged — treat as success.
            console.warn('[reminders] log err for', inv.number, key, logErr.message);
          }
          fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'sent' });
        } catch (e) {
          console.error('[reminders] send exception', inv.number, key, e);
          fired.push({ invoice_id: inv.id, rule_key: key, to: toEmail, status: 'send-exception', error: (e as Error).message });
        }
      }
    }

    return json({ today, dry_run: dryRun, fired_count: fired.length, fired });
  } catch (e) {
    console.error('[reminders] fatal', e);
    return json({ error: (e as Error).message }, 500);
  }
});

// ─── helpers ──────────────────────────────────────────────────────────────

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// YYYY-MM-DD in America/Chicago (Baylor's timezone) so "today" feels right to her.
function todayISO(): string {
  const fmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit' });
  return fmt.format(new Date());
}

// Days between two YYYY-MM-DD dates, positive if `a` is after `b`.
function dayDiff(aISO: string, bISO: string): number {
  const a = new Date(aISO + 'T00:00:00Z').getTime();
  const b = new Date(bISO + 'T00:00:00Z').getTime();
  return Math.round((a - b) / 86400000);
}

// A rule fires when today equals due_date + offset (negative for 'before').
function ruleFiresOn(rule: any, dueDate: string, today: string): boolean {
  const diff = dayDiff(today, dueDate); // today − due
  if (rule.when === 'due') return diff === 0;
  if (rule.when === 'before') return diff === -Math.abs(rule.days);
  if (rule.when === 'after')  return diff === Math.abs(rule.days);
  return false;
}

function ruleKey(rule: any): string {
  if (rule.when === 'due') return 'due';
  return `${rule.when}-${rule.days}`;
}

// Replicates index.html getEffectiveReminderSchedule.
function getEffectiveSchedule(inv: any, studioInfo: any): any[] {
  const override = inv.reminder_override;
  const stored = studioInfo.reminderDefaults || {};
  const typeDefault = Array.isArray(stored[inv.type]) ? stored[inv.type] : (BUILTIN_REMINDER_DEFAULTS[inv.type] || []);
  const base = Array.isArray(override) ? override : typeDefault;
  const hasDue = base.some((r: any) => r.when === 'due');
  if (hasDue) return base;
  return [{ id: 'due-default', days: 0, when: 'due', templateId: 'builtin-due-today' }, ...base];
}

// Resolve a templateId: custom user template → built-in + override → built-in.
function resolveTemplate(templateId: string, studioInfo: any): { subject: string; body: string } | null {
  const customList: any[] = studioInfo.emailTemplates || [];
  const custom = customList.find(t => t.id === templateId);
  if (custom) return { subject: custom.subject || '', body: custom.body || '' };
  const builtin = DEFAULT_EMAIL_TEMPLATES[templateId];
  if (!builtin) return null;
  const overrides = studioInfo.emailTemplateOverrides || {};
  const o = overrides[templateId];
  return { subject: o?.subject ?? builtin.subject, body: o?.body ?? builtin.body };
}

function buildTemplateContext(inv: any, studioInfo: any, studio: any, client: any, project: any): Record<string, string> {
  const name = client?.name || '';
  return {
    'client.name': name,
    'client.firstName': name.split(' ')[0] || '',
    'client.email': client?.email || '',
    'client.phone': client?.phone || '',
    'project.name': project?.name || '',
    'project.address': '',
    'invoice.number': inv.number || '',
    'invoice.total': fmtMoney(inv.total),
    'invoice.dueDate': inv.due_date || '',
    'invoice.sentDate': inv.sent_date || '',
    'invoice.phase': inv.phase || '',
    'studio.name': studio?.name || '',
    'studio.email': studioInfo.email || '',
    'studio.phone': studioInfo.phone || '',
    'me.name': studioInfo.senderName || studio?.name || '',
  };
}

function fillTemplate(str: string, ctx: Record<string, string>): string {
  return String(str || '').replace(/\{([^}]+)\}/g, (m, k) => {
    const v = ctx[k.trim()];
    return v != null ? v : m;
  });
}

function fmtMoney(n: any): string {
  const x = Number(n || 0);
  return '$' + x.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

async function resolveLogoDataUrl(sb: any, studioInfo: any): Promise<string | null> {
  const path = studioInfo.logo?.storagePath;
  if (!path) return null;
  try {
    const { data: signed } = await sb.storage.from('files').createSignedUrl(path, 3600);
    if (!signed?.signedUrl) return null;
    const r = await fetch(signed.signedUrl);
    if (!r.ok) return null;
    const blob = await r.blob();
    if (blob.size > 200 * 1024) return null; // keep email slim
    const buf = new Uint8Array(await blob.arrayBuffer());
    const b64 = btoa(String.fromCharCode(...buf));
    const type = blob.type || 'image/png';
    return `data:${type};base64,${b64}`;
  } catch (_e) { return null; }
}

function esc(s: any): string {
  return String(s || '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' } as any)[c]);
}

// Mirror of buildInvoiceEmailHtml() in index.html — kept minimal for reminders
// (line items omitted to keep payload small; client already saw them in original send).
function buildInvoiceEmailHtml({ inv, studio, studioInfo, client, project, message, payUrl, logoUrl }: any): string {
  const si = studioInfo || {};
  const clientName = client?.name || '';
  const mahogany = '#5B2D22', border = '#bfb19a', bg = '#FAF6EE', textDark = '#1a1108', textMid = '#4a3a2a';
  const line = `<tr><td style="border-top:1px solid ${border};height:1px;line-height:1px;font-size:0">&nbsp;</td></tr>`;
  return `
<!doctype html><html><head><meta charset="utf-8"><title>Invoice ${esc(inv.number)}</title></head>
<body style="margin:0;padding:0;background:${bg};font-family:'Courier New',Courier,monospace;font-weight:700;color:${textDark}">
<table width="100%" cellpadding="0" cellspacing="0" style="background:${bg};padding:32px 0"><tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;background:#fff;border:1px solid ${border}">
<tr><td style="padding:32px 36px 20px">
  ${logoUrl ? `<img src="${esc(logoUrl)}" alt="${esc(studio?.name || '')}" style="max-height:56px;max-width:200px;display:block;margin-bottom:14px">` : ''}
  <div style="font-family:'Oswald',sans-serif;font-weight:600;font-size:20px;letter-spacing:0.08em;color:${mahogany};text-transform:uppercase">${esc(studio?.name || 'Studio')}</div>
  <div style="font-size:11px;color:${textMid};margin-top:4px;line-height:1.6;white-space:pre-wrap;font-weight:700">${[si.address1, si.address2, si.phone, si.email, si.website].filter(Boolean).map(esc).join('\n')}</div>
</td></tr>
${line}
<tr><td style="padding:20px 36px">
  <div style="font-family:'Oswald',sans-serif;font-weight:700;font-size:22px;letter-spacing:.14em;color:${textDark};text-align:center">I N V O I C E</div>
  ${project ? `<div style="font-family:'Courier New',monospace;font-size:12px;color:${textDark};text-align:center;margin-top:6px;letter-spacing:.05em;text-transform:uppercase;font-weight:700">${esc(project.name || '')}</div>` : ''}
  ${message ? `<div style="background:${bg};border:1px solid ${border};padding:14px 18px;margin-top:18px;font-family:'Courier New',monospace;font-weight:700;font-size:13px;line-height:1.6;color:${textDark};white-space:pre-wrap">${esc(message)}</div>` : ''}
</td></tr>
${line}
<tr><td style="padding:18px 36px"><table width="100%" cellpadding="0" cellspacing="0">
  <tr><td style="font-size:11px;color:${textMid};text-transform:uppercase;letter-spacing:.1em"><strong style="color:${textDark}">Invoice</strong> ${esc(inv.number)}</td>
  <td style="font-size:11px;color:${textMid};text-transform:uppercase;letter-spacing:.1em;text-align:right"><strong style="color:${textDark}">Due</strong> ${esc(inv.due_date || '—')}</td></tr>
  ${clientName ? `<tr><td colspan="2" style="font-size:12px;color:${textMid};padding-top:8px">Billed to: <strong style="color:${textDark}">${esc(clientName)}</strong></td></tr>` : ''}
  <tr><td colspan="2" style="font-size:12px;color:${textMid};padding-top:8px">Balance due: <strong style="color:${textDark}">${fmtMoney(inv.total)}</strong></td></tr>
</table></td></tr>
${line}
<tr><td align="center" style="padding:24px 36px 32px">
  <a href="${esc(payUrl)}" style="display:inline-block;background:${mahogany};color:#fff;text-decoration:none;padding:14px 28px;font-family:'Oswald',sans-serif;font-size:13px;font-weight:600;letter-spacing:.12em;text-transform:uppercase">Review &amp; Pay Invoice</a>
  <div style="font-family:'Courier New',monospace;font-weight:700;font-size:11px;color:${textMid};margin-top:10px">ACH (no fee) · Credit / Debit · Wire · Check</div>
</td></tr>
<tr><td style="background:${bg};padding:16px 36px;text-align:center;font-family:'Courier New',monospace;font-weight:400;font-size:10px;color:${textMid}">
  Questions? Reply to this email or contact ${esc(si.email || si.phone || '')}
</td></tr>
</table></td></tr></table></body></html>`.trim();
}

function buildInvoiceEmailText({ inv, studioInfo, payUrl, message }: any): string {
  return [
    `Invoice ${inv.number} from ${studioInfo?.name || 'Studio'}`,
    '',
    message ? message + '\n' : '',
    `Total: ${fmtMoney(inv.total)}`,
    `Due: ${inv.due_date || '—'}`,
    '',
    `Pay online: ${payUrl}`,
    '',
    'ACH, Credit Card, Wire, or Check — pay however works best.',
  ].filter(Boolean).join('\n');
}
