# BEEP HQ — Work List (Cowork-generated, Baylor-approved; living document)

> Saved to the repo 2026-07-29 so the governing plan lives next to the code.
> Sections 0–2 (incl. 2.8 remediation) are COMPLETE except owner config
> actions. Ground rules adapted for solo flow: safety substance kept
> (additive-only schema, stated rollbacks, dry-run data touches, sync-engine
> isolation), PR/branch/flag ceremony dropped, pushes go to main.

## Status ledger

| Section | Status |
|---|---|
| 0 Ground rules | Adapted + adopted |
| 1 Pre-flight | Done (PITR=off ⚠ owner decision; JSON backup taken 2026-07-29; partial-load guard verified present; new-table registration documented in ARCHITECTURE.md) |
| 2 Tax audit + 2.8 remediation | **COMPLETE** — TAX-AUDIT.md + all 5 remediation steps shipped |
| 3.2 Notes split | **DONE** (Client Description field; notes internal-only) |
| 3.5.1 Cascade | **DONE** (brand-first, carriers-only, matrix contacts) |
| 3.5.2 Notifications overhaul | **DONE 2026-08-03** (dcfcda2, phase0_63) — audit fixed silent task-comment mention gap; inline bodies; Clear=dismissed_at; Reply-to-thread; history modal |
| 3.1 status_kind mapping | **DONE 2026-08-03** (66dd2e9) — built-ins were already rename-safe; gap was custom statuses invisible to automations; statusKind() + "Acts as" dropdown |
| 3.3 Cost-side currency/FX | Queued (BIG — pricing-chain scope, not "small debt") |
| 4.1–4.8 Design features | 4.1 item specs **DONE 2026-08-04** (3cac5c6, phase0_65); 4.2 schedule generation **DONE 2026-08-04** (4bcecfe); 4.3+ queued in order |
| 5 SaaS gaps | Parked until §4 + pricing decision |
| 6 Aug 3 batch | **SHIPPED 2026-08-03** (all code items): 6A.1-9 (reconciliation + phase0_61, rounding, periods, clean lines, reconcile tool, h/m, billed-collapse, single timer, biweekly payroll v1), 6B mobile 0.5.0 build 14 → TestFlight, 6C deposits (payment ledger in cost_actual_meta), 6D.2-4 (freight rows, missing-data filter, order_groups phase0_62), 6E.1-4. Open (Baylor input): 6D.1 "Collected"→"Billed" relabel decision, 6F spam (forward headers + DMARC p=quarantine owner action) |

## Owner config actions (no code) — still open
- Configure **Georgia** in Settings → Sales Tax (state + county components); verify in staging before any live GA project
- **Louisiana**: replace flat 10% with CPA-verified composition (≈5% state + 5% Orleans Parish; confirm Murdock address isn't in a special district)
- Fill the **Mississippi resale number**
- **Enable PITR** (Supabase → Database → Backups) — recommended
- **DMARC** upgrade to p=quarantine (GoDaddy TXT `_dmarc`)
- Supabase Auth **Redirect URLs**: `https://hq.beepdesign.co/**` + Site URL
- Begin using the **filing tracker** (now reconciles filed vs computed)

---

## 3.5.2 Work → notifications: deep links, inline notes, reply, backlog — NEXT UP

**Goal:** a notification should be actionable without leaving the Work view,
and dismissing one should never destroy it.

**a) Clickable deep links** — every notification links to the exact location
that generated it via `link_entity_type`/`link_entity_id`, reusing the
UI-state-restore machinery. Audit first: report which notification types
populate the link fields and which leave them null; fix the write paths
(not historical rows).

**b) Inline message body** — @mention notifications render the note/comment
body in the card. Sources: `task_comments.mentions[]`,
`activity_entries.mentions[]`, item/component `activity_log` jsonb (report
any others). Store enough in `notifications.payload` to render without a
second fetch; source record stays canonical.

**c) Three actions** — Clear (new nullable `dismissed_at timestamptz`,
distinct from `read_at`; queue filters `dismissed_at is null`), Open
(deep-link), Reply (post to originating thread: `task_comments` for tasks,
`activity_log`/`activity_entries` for items/components; notify author +
@mentions).

**d) Backlog view** — "All notifications" history tab incl. dismissed,
filterable by type/date, same deep links. Keep indefinitely.

Rollback: drop `dismissed_at`; revert commit.

## 3.1 status_kind mapping — queued

Map pipeline automation hooks to a stable `status_kind` instead of the
display key. Statuses are user-configurable; renaming one silently breaks
automation. Medium risk (touches paid→status automation) — own pass.

## 3.3 Cost-side currency + FX — queued (BIG)

Currency + captured FX rate on `net_price`/`net_cost` so UK/Italian vendor
costs record natively. Client billing stays USD. NOTE: mislabeled "small"
in the original doc — net cost feeds the canonical pricing chain, estimate
snapshots, P&L, projected profit. Plan as a full feature session.

## 4. Design features — strictly sequenced, stop for review after each

### 4.1 Item spec system (keystone)
`item_field_defs` table (studio-scoped, keyed to `item_type_id`, following
`task_field_defs` exactly) + nullable `spec jsonb` on proposal_items and
proposal_components. Settings UI under Item Types (field key, label, type,
options, required, sort). Item detail renders the set for the item's type,
conditional on readymade/openline/constructed. Seed sets: Upholstery,
Curtains/Drapery, Lighting, Rugs, Case Goods, Millwork, Paint/Finish,
Wallcovering. Rollback: drop table + column.

### 4.2 Schedule generation from items
Generator creating a `documents` record from a project's items filtered by
category, pulling `spec` values; feeds existing doc editor + versions.
Hand-editable output. Depends on 4.1.

### 4.3 The four small ones
`proposal_spaces.intent text`; `proposal_items.tags text[]` + PM tag
filter; `time_entries.proposal_item_id` FK; open-line parameters in `spec`
(dimensional range, finish family, exclusions, reference image,
resolve-by date, who resolves).

### 4.3b The trim pass (value engineering)
`projects.budget_target numeric`; running total vs target while editing;
**estimate diff view** (compare any two `estimates.snapshot`s → add/remove/
change list with deltas); **convert-to-allowance** one-click (type →
openline, intent kept in spec, lower allowance, resolve-by date). No
approval workflow — visibility during negotiation.

### 4.4 Alternates
`proposal_item_alternates` table (item_id, vendor_id, brand_id, name, sku,
note, sort_order); ⇄ Substitute opens with pre-vetted alternates loaded.

### 4.5 Reason capture
Optional free-text reason on activity-logging write paths (price adjust,
substitution, sourcing change, status change on approved item).

### 4.6 Substitution notice document
`documents` record diffing current item vs `estimates.snapshot`: price Δ,
lead-time Δ, what it touches (via 4.3 tags). Existing PDF export.

### 4.7 Repertoire library
`library_items` (brand_id, vendor_id, name, pattern_no, category,
use_notes, hand_notes, status, successor_id, last_verified_at). NO prices,
NO stock. `library_item_id` FK on proposal_items. "Where I've used it" =
query by FK. Observed lead time aggregated from referencing items.

### 4.8 Room boards
`space_candidates` (space_id, name, image_path, link, note, source,
status candidate/promoted/parked). Promote-to-item copies into a real
proposal_items row. NOT a fourth proposal_items.type. Studio-level parked
board.

## 5. SaaS gaps — parked (after §4 + pricing decision)
1. Stripe Connect (hard gate — no second studio invoices before it)
2. Per-tenant email identity
3. Doc/PDF layouts as per-studio templates
4. Remaining §13 de-hardcoding
5. Self-serve onboarding
6. Subscription billing (entitlement gates writes only; fail open)
7. Import/export
8. Per-project lazy loading before real-volume customers

## 6. August 3, 2026 batch (Baylor's update memo)

> **Deadline context:** Baylor intends to run the studio fully on the app
> effective **Sept 1, 2026**. Blockers for that date are the time system
> (§6A) and email deliverability (§6F). Real production data everywhere —
> never erase or rewrite existing time entries/invoices; reconciliation
> backfills must be additive and dry-run first.

### 6A. Time system overhaul — CRITICAL PATH for Sept 1

> **Baylor's design decisions (locked 2026-08-03):** rounding default =
> period TOTAL rounded up to next 30 min (both modes still selectable per
> run); historical cleanup = manual "Mark as billed" reconcile tool
> (dry-run, nothing deleted); payroll = BIWEEKLY on MONDAYS, anchor: Olivia
> paid Mon 2026-08-03; payroll period view must show hours by project,
> billable/non-billable split, gross pay math (rate visible), payment
> history + outstanding, AND revenue generated (her billable time at bill
> rates); invoice line = one per person "Project Hours, [Name]", qty =
> rounded hours, rate = billable rate, custom-description override kept;
> non-billable time = never on invoices/revenue, but IS a labor expense in
> P&L/gross-net AND always in payroll; duration format = "1h 32m" in all
> UI overviews, decimal hours on invoice lines.

- **6A.1 Invoice-time reconciliation (the core bug).** Time placed on a
  sent invoice must be marked billed (link entries → invoice) and drop out
  of the unbilled tally; unbilled = time since last reconciled period.
  Known failure: BE-114 has 28h billed + paid, yet Goff Chandler still
  shows 30.01h unbilled. Must handle invoice delete/void/cancel (entries
  return to unbilled). Backfill path for historical invoices (BE-114 et
  al) — additive, dry-run, no data erased.
- **6A.2 Rounding options** when adding unbilled time: round each entry up
  to next 5/10/15/30 min, OR round the period total up to next 15/30/60.
- **6A.3 Period selection.** Default = all time since last reconciled
  (billed) time; adjustable: all time, this/last month, last week, last
  60/90 days, since last period, custom.
- **6A.4 Clean line-item text.** Auto-generated time lines read simply
  "Project Hours, [User's name]" — kill the messy auto text.
- **6A.5 Payroll periods.** Manage/filter/reconcile pay periods so paying
  a team member shows enough info (ties into queued Time+Payroll feature:
  pay rate vs billable rate decoupled).
- **6A.6 Duration format.** Overviews show "1h 32m", not "1.51 hours".
- **6A.7 Non-billable integrity.** Non-billable entries must be excluded
  from financial time tallies and time invoicing everywhere.
- **6A.8 Entry list UX.** Project time section: entries by user,
  reverse-chronological; billed entries collapse into a "Billed entries"
  area with per-user collapsible sublists.
- **6A.9 Single running timer per user, cross-device.** Olivia had two
  timers running (web + phone). Enforce server-side (one open timer per
  user) + surface the running timer on every device.
- **6A.10 Reference research: DONE 2026-08-03** — see
  `docs/time-billing-research.md`. Verdict: copy Bonsai's entry-level billed
  status + invoice FK (BEEP's schema already matches), Bonsai's
  delete-invoice fork (revert vs discard hours) + manual mark-billed
  override (= the backfill tool), Toggl's rounding option set (up/nearest/
  down × increments, per-entry or per-group-subtotal, raw durations never
  mutated), Toggl's approved-timesheet-as-locked-payroll-period, Bonsai's
  clean lines + optional timesheet appendix.

### 6B. Mobile app (beep-mobile)

- **6B.1 Cancel entry.** Top-left red "Cancel entry" text button, appears
  once any field has data; confirm dialog "Are you sure you'd like to
  cancel this entry? This cannot be undone" (Yes/No); clears all fields.
- **6B.2 Tag expense → PM item.** After selecting a project, allow tagging
  an expense to a PM item from the phone.
- **6B.3 BUG: time-entry notes not saving** from the mobile app.

### 6C. Cost actuals — deposits / partial payments

- **6C.1 Deposit recording.** Vendors may take 50% upfront, flat fee, etc.
  Record a cost actual as a deposit; item stays flagged "deposit
  outstanding" until user records the balance and marks paid in full.
  Must roll up correctly in the project Budget tab and the financial
  dashboard (design proposal first — see session notes).

### 6D. PM + proposals

- **6D.1 P/L math walkthrough.** Explain cost actuals, delta
  (credit/overage), freight actuals, item P/L, raw actual — sources +
  formulas; fix anything actually wrong.
- **6D.2 Freight logged-actuals rows** show: [Date logged] [Category]
  [Component (if constructed)] [Vendor (if entered)] + the amount.
- **6D.3 Proposal filter:** show only items WITHOUT net price / vendor /
  item code / category (checkboxes, combinable).
- **6D.4 Shared-order tagging.** Internal note linking multiple
  items/components that are really one vendor order (same fabric on sofa +
  curtains; same wallpaper in two rooms). Easily untagged per item when a
  substitution splits the order. Design proposal first.

### 6E. Document builder — material schedule

- **6E.1** "Unassigned" default room renameable inline.
- **6E.2** Creating a schedule for a project auto-populates its spaces
  (deletable afterwards).
- **6E.3** Image text fields relabeled "Header" / "Caption".
- **6E.4 BUG:** image added by one user shows placeholder but not the
  image on another user's account, and doesn't print. Cross-account image
  resolution must work.

### 6F. Email deliverability

- **6F.1** Invoice emails landing in spam despite Resend showing
  delivered. Investigate (DMARC upgrade already an open owner action;
  check headers, from-domain alignment, content triggers, List-Unsubscribe).
