# Resend deliverability — DNS checklist for `@beepdesign.co`

## The problem

Self-sends to `@beepdesign.co` recipients (e.g. invoice reminders Baylor sends to her own studio mailbox) land in **GoDaddy M365 Proofpoint quarantine**, not the inbox.

This is a DNS + M365 policy problem, not a code problem. Outbound mail leaves Resend correctly. The receiving server (Proofpoint, fronting Microsoft 365) rejects or quarantines it because the mail is coming from a *third party* (Resend) claiming to be `@beepdesign.co`, and the domain's SPF / DKIM / DMARC / M365 anti-spoofing rules haven't been told that Resend is authorized.

Until the DNS records below are in place, mail from Resend on behalf of `@beepdesign.co` will continue to be quarantined or rejected by Proofpoint/M365.

**Workaround while blocked:** Test self-sends with a non-`@beepdesign.co` recipient (any gmail/icloud/etc. account works). Real client sends to non-`@beepdesign.co` recipients are not affected by this issue.

## Pre-work — collect the values from Resend

Before touching DNS, log into the Resend dashboard and grab the DKIM CNAME values for the `beepdesign.co` domain:

1. Open https://resend.com/domains
2. Click `beepdesign.co` (add it as a domain if not already present)
3. Resend will display three CNAME records under "DKIM" — names like `resend._domainkey.beepdesign.co` and similar
4. Copy the three CNAME `name` + `value` pairs verbatim

Keep that page open — you'll paste those into GoDaddy.

## DNS changes (in GoDaddy)

GoDaddy DNS console: https://dcc.godaddy.com/manage/beepdesign.co/dns

### 1. SPF — update the existing `TXT @` record

There is likely already an SPF record for M365. **Don't add a second SPF record** — that breaks SPF entirely. Edit the existing one and add Resend.

| Field | Value |
|---|---|
| Type | `TXT` |
| Name | `@` |
| Value | `v=spf1 include:spf.protection.outlook.com include:_spf.resend.com ~all` |

The order of `include:` directives doesn't matter; `~all` (softfail) at the end stays.

### 2. DKIM — add 3 new CNAME records

Paste the three records from the Resend dashboard. They'll look roughly like:

| Type | Name | Value |
|---|---|---|
| CNAME | `resend._domainkey` | (long string from Resend) |
| CNAME | (Resend-provided name) | (Resend-provided value) |
| CNAME | (Resend-provided name) | (Resend-provided value) |

Use Resend's exact names/values; the above is just the shape.

### 3. DMARC — add a `TXT _dmarc` record (start permissive)

| Field | Value |
|---|---|
| Type | `TXT` |
| Name | `_dmarc` |
| Value | `v=DMARC1; p=none; rua=mailto:dmarc-reports@beepdesign.co; fo=1` |

`p=none` = monitor-only. We start here so DMARC failures don't bounce real mail while we're verifying alignment. After 1–2 weeks of clean reports, this can be tightened to `p=quarantine` and eventually `p=reject`.

(If the `dmarc-reports@beepdesign.co` mailbox doesn't exist yet, either create it or drop the `rua` parameter for now — DMARC works without it.)

### 4. Verify in Resend

Back in https://resend.com/domains, click "Verify" next to `beepdesign.co`. All three (SPF, DKIM, DMARC) should turn green within minutes — GoDaddy's TTL is usually 1 hour. If anything stays red after an hour, the record was pasted incorrectly.

## M365 admin (the second blocker)

Even with perfect DNS, Microsoft's anti-spoofing intelligence often quarantines mail that claims to come from your own domain via a third party. You need an explicit allowlist.

M365 admin center: https://admin.microsoft.com → Security & compliance → Anti-spam → Anti-spam inbound policy

1. Open the **default inbound policy** (or the policy that covers `@beepdesign.co`)
2. Find **Allowed senders and domains**
3. Add `*.resend.com` to allowed domains, or specifically add the Resend sending IPs (listed in Resend's deliverability docs)

If GoDaddy fronts the M365 admin (this is common when M365 was purchased through GoDaddy), the URL will be different — call GoDaddy support and ask them to whitelist `resend.com` for inbound anti-spoofing on `@beepdesign.co`.

## How to verify it worked

1. From the web app, trigger a self-send (e.g., send an invoice to your own `@beepdesign.co` address).
2. Wait 60 seconds. Check inbox AND M365 quarantine.
3. If it arrived in inbox: done.
4. If it's still in quarantine: open the quarantined message and view the raw headers. Find the `Authentication-Results:` line. It will tell you which check failed:
   - `spf=fail` → SPF record didn't include Resend; re-check step 1
   - `dkim=fail` → DKIM CNAMEs missing or wrong; re-check step 2
   - `dmarc=fail` → DMARC needs alignment between the From: header and SPF/DKIM domain
   - `compauth=fail` → M365 anti-spoofing intelligence flagged it; finish step 4 (admin allowlist)

Send the `Authentication-Results:` line back to me and I can point at exactly which fix is needed.

## Why I can't do this for you

DNS changes require login to GoDaddy. M365 anti-spoofing changes require login to the Microsoft 365 admin center (or GoDaddy support's help if M365 was purchased through them). Neither is something I can poke at from code. Once DNS is live, the existing Resend integration in the app will just start working — no code change required.
