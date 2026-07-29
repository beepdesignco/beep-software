# BEEP HQ — Architecture

> Documentation snapshot generated 2026-07-29 from the live schema and codebase.
> The database column listings below were dumped from the production Postgres
> `information_schema`, not reconstructed from migration files.

---

## 1. Stack

| Layer | Technology |
|---|---|
| **Frontend** | Single-file vanilla JavaScript app — the entire web app lives in `index.html` (~40k lines: HTML views, CSS, and one `<script>` block). No framework, no build step, no bundler. Chart.js is the only charting dependency; jsPDF + autotable for PDF generation. |
| **Language** | Plain ES2020+ JavaScript. Edge functions are TypeScript (Deno). |
| **Database** | Supabase Postgres (project `hceoxzzybzrjeqhwhvxf`, "DESIGN HQ"). 49 tables, Row-Level Security on everything. |
| **Auth** | Supabase Auth (email + password). One `studios` row per studio; membership + permissions via `studio_members`. Password reset / invite links land on the app's set-password screen (`type=recovery|invite|signup` hash detection). |
| **Hosting** | Static hosting behind Cloudflare at **hq.beepdesign.co**. Deploys by pushing to `main` on GitHub (`beepdesignco/beep-software`). The client-facing pay page is a separate static file at `/pay/`. |
| **File storage** | Supabase Storage, single bucket `files`, paths namespaced `{studioId}/{entity}/{entityId}/{uuid}.{ext}`. Signed URLs for reads; vendor logos etc. |
| **Edge functions** (Deno, in `supabase/functions/`) | `get-invoice-for-payment` (public pay-page data by payment token), `create-checkout-session` + `stripe-webhook` + `stripe-refund` (Stripe), `send-email` (Resend, enforces `can_send_invoices` server-side), `run-invoice-reminders` (cron reminders). Deploy via `./deploy-edge.sh <name>`. |
| **External services** | **Stripe** (live mode — card + ACH invoice payments, refunds, webhooks), **Resend** (transactional email from `hello@beepdesign.co`; SPF/DKIM/DMARC configured on `beepdesign.co` + `send.beepdesign.co`), **Expo/EAS + TestFlight** (companion iOS app, separate repo `/Users/baylorpillow/beep-mobile`, same Supabase backend). |
| **Mobile** | BEEP HQ iOS (Expo/React Native), TestFlight distribution, currently v0.4.0. Sign-in, Log Time, Log Expense, Documents (read), Invoices (view + record payment), cross-device timer. |

### Core runtime architecture

- **In-memory state `S`** — one big object holding every entity list (`S.projects`,
  `S.invoices`, `S.proposals[pid]`, `S.expenses`, …). Loaded once at sign-in by
  `loadFromSupabase()` (a parallel `Promise.all` of ~28 table selects), mirrored to
  `localStorage` (`beep_hq_v1`) on every `save()`.
- **Sync engine** — `save()` → 50 ms debounce → `syncToSupabase()`. For each table a
  *shadow snapshot* (`_sbShadow.*`, Maps of deep clones) is diffed against current
  state; changed rows upsert, missing rows soft-delete. Two hardening guarantees:
  shadows are snapshotted **at diff time** (concurrent mutations during the awaited
  upsert can't be marked "already persisted"), and upserts use `.select('id')` so
  rows silently dropped by RLS stay out of the shadow and retry with a warning.
- **Realtime** — Supabase `postgres_changes` subscriptions patch `S` in place *and*
  re-align the shadow (so the local writer neither re-pushes nor clobbers), then
  re-render only the visible surface, deferring around active input focus.
  Live-synced tables: `proposal_items`, `proposal_components`, `proposal_spaces`,
  `studios`, `time_entries`, `expenses`, `freight_actuals`,
  `freight_actual_allocations`, `projects`, `invoices`, `invoice_payments`,
  `clients`, `notifications`, `activity_entries`. Everything else is load-once.
- **UI state restore** — `beep_ui_v1` in localStorage persists the exact location
  (view, project, tab, budget sub-tab, open PM item) across refreshes.

---

## 2. Data model — complete schema

Everything is scoped by `studio_id → studios` (multi-tenant-ready even though one
studio uses it today). Nearly every table carries `created_at`, `updated_at`,
`deleted_at` (soft delete), and `created_by_user_id`/`updated_by_user_id`; those
are omitted from the field lists below for brevity but exist unless noted.

### ER summary

```
studios ─┬─ studio_members ── member_rates (1:1, wage)
         ├─ clients ── contacts (legacy person records)
         ├─ projects ─┬─ project_contacts ──> contacts
         │            ├─ proposal_spaces ── proposal_items ── proposal_components
         │            ├─ estimates (immutable snapshots once locked)
         │            ├─ documents ── document_versions (revision history)
         │            ├─ submittals ── submittal_signers
         │            ├─ project_meetings
         │            ├─ freight_actuals ── freight_actual_allocations ──> items/components
         │            ├─ freight_settlements ──> invoices
         │            └─ client_fees ──> items/components, invoice_line_items
         ├─ invoices ─┬─ invoice_line_items ──> items/components/expenses/settlements
         │            ├─ invoice_payments (Stripe or manual)
         │            ├─ invoice_freight_allocations ──> items/components
         │            ├─ invoice_sends (email log)
         │            └─ invoice_views (client open tracking)
         ├─ expenses ── expense_allocations ──> items + invoice_line_items
         ├─ vendors ─┬─ vendor_contacts (reps, carry brand_ids[])
         │           ├─ vendor_brands (M2M) ──> brands
         │           └─ vendor_credential_access_log (audit)
         ├─ brands (categories[] = offerings)
         ├─ item_types (categories for items, optional default markup)
         ├─ freight_categories / freight_charges (proposal-side freight)
         ├─ purchase_orders
         ├─ tasks ─┬─ task_comments / task_activity / task_dependencies
         │         └─ task_field_defs / task_notes
         ├─ time_entries ──> projects, tasks, invoice_line_items
         ├─ payroll_runs (immutable pay-period ledger)
         ├─ notifications (per-recipient)
         ├─ activity_entries (cross-entity activity/work feed)
         └─ embeddings / app_config (infrastructure)
```

### Identity & team

**studios** — `id`, `name`, `owner_user_id` (frozen by trigger),
`studio_info jsonb` (letterhead: name/address/logo/wire instructions/check
address/default freight markup/invoice note presets/**paymentMethodsConfig**),
`settings jsonb` (shared taxonomy blob — see below).

The `settings` blob keys: `vendor_types[]`, `categories[]` (brand offerings),
`qty_units[]`, `payment_cards[]`, `status_colors{}`, `status_labels{}`,
`custom_item_statuses[]`, `pipeline_status_order[]`, `task_status_colors{}`,
`tax_states[]` (state + rateComponents + resale#), `tax_filings[]`,
`sales_tax_tracker_enabled/start_date`. Members may write the blob (shared
taxonomy must save for everyone) but a DB trigger rejects non-owner changes to
the tax keys.

**studio_members** — `user_id` (auth), `role` ('owner'/'member'), `display_name`,
`job_title`, `phone`, `hourly_rate` (billable-rate default, member-visible),
`preferences jsonb` (theme etc.), `invited_at`, `accepted_at`, and permission
flags: `can_view_financials` (default true), `can_record_payments`,
`can_send_invoices`, `can_manage_expenses`, `can_manage_members`,
`can_adjust_time_entries` (default true), `can_view_vendor_credentials`,
`can_edit_project_settings` (default true), `can_edit_invoices` (default true),
`can_run_payroll`. A trigger freezes rates/role/flags against non-owner edits.

**member_rates** — `member_id` (PK → studio_members), `pay_rate` (wage).
Readable/writable only by owner + `can_run_payroll` holders.

### CRM

**clients** — `name`, `email`, `phone`, `address`, `notes`.
**contacts** — legacy person records (`client_id`, `name`, `company`, `role`, …).
**vendors** — `name`, `vendor_type`, `website/phone/email/address/notes`, and
pgcrypto-encrypted portal credentials (`credentials_username_enc/password_enc/
account_enc` bytea + audit fields). Decryption only via `security definer` RPCs
gated on `can_view_vendor_credentials`; every reveal is written to
**vendor_credential_access_log** (`vendor_id`, `user_id`, `action`, `occurred_at`).
**vendor_contacts** — reps: `vendor_id`, `name/title/email/phone/notes`,
`primary_contact`, `brand_ids uuid[]` (which brands this rep covers).
**brands** — `name`, `notes`, `categories text[]` (offerings, e.g. "Lighting").
**vendor_brands** — M2M `(vendor_id, brand_id)`.

### Projects & proposals (see §3 for the deep dive)

**projects** (26 cols) — `client_id`, `name`, `stage`, `type`, address
(`street/city/state/zip`), `markup_pct` (default 25), `tax_rate`, `tax_freight`,
`time_taxable`, `install_date_value` + `install_date_precision` (day/week/month),
`files jsonb` (the project Documents-tab uploads: `{id,name,size,type,
storagePath,uploadedAt,displayName,folders[]}`), `address_book jsonb`,
`quick_references jsonb`, `settings jsonb` (per-project: freightMarkupPct,
jurisdictions[], credits[] — the project credit pool `{id,source,balance,amount,
note,created,draws[]}`), `notifications jsonb`.

**proposal_spaces** — `project_id`, `name`, `note`, `sort_order`.

**proposal_items** (57 cols) — full listing in §3.

**proposal_components** (37 cols) — children of constructed items; full listing in §3.

**estimates** — the client-facing estimate/proposal document: `project_id`,
`name`, `status` ('draft'/'proposed'/'approved'), `proposed_at`, top-level
charges (`freight`, `freight_taxable`, `hours`, `hourly_rate`, `receiving`,
`storage`, `tariffs_pct`), `custom_lines jsonb`, and **`snapshot jsonb`** — a
deep clone of the proposal spaces/items/components taken at save time. Locked
estimates are immutable in the UI.

**project_meetings** — `meeting_at timestamptz`, `title`, `notes`, `attendees`,
`created_by`.

**documents** — generated docs (schedules, work orders): `project_id`,
`template_id`, `title`, `current_version_id` → **document_versions**
(`version_letter`, `revision_number`, `data jsonb` — the full doc content
including items/rooms/notes/exportConfig/work-order blocks, `files jsonb`).
This is a real revision-history system: every save pushes a version row.

**submittals** — `project_id`, `document_id`, `title`, `notes`, `files`,
`sent_at`, `completed_at`; **submittal_signers** — per-signer sign-off state.

**purchase_orders** — `project_id`, `vendor_id`, `vendor_contact_id`,
`po_number int`, `status` (v_draft → sent → acknowledged → shipped → received →
closed/cancelled with timestamp columns for each), `sidemark`, ship window,
`files jsonb`.

### Money — invoices

**invoices** (36 cols) — `project_id`, `client_id`, `number` ("BE-###"), `type`
(phased/monthly/standalone/design_fee), `status` (draft/sent/partial/paid/
cancelled), `phase`, `sent_date`, `due_date`, `notes` + `note_selections jsonb`
(preset note ids), totals (`subtotal` — items only, `freight`,
`freight_taxable`, `adjacent_charges` + `adjacent_charges_taxable_amount`,
`discount_type/value/discount`, `cc_fee_pct/cc_fee`, `tax_rate/tax`, `total`),
`files jsonb`, `payment_token uuid` (public pay-page link),
`stripe_checkout_session_id`, `watermark_mode`, `reminder_override jsonb`,
`freight_retainer jsonb` (`{pct, item_ids[]}`).

**invoice_line_items** — `invoice_id`, `name`, `description` (client-visible),
`qty`, `price`, `taxable`, `manual`, `track_in_pm`, `sort_order`, links:
`proposal_item_id`, `proposal_component_id`, `expense_id`, `settlement_id`,
`recon_type` ('credit'/'overage'/'deferred' — credit lines render in the totals
block, not the item list), `client_hidden` (line + its covering credit are
excluded from all client documents), `covers_line_id` (credit ↔ covered-line
pairing).

**invoice_payments** — `date`, `amount` (negative = refund), `method`, `notes`,
`receipt_path`, `pending` (in-flight ACH — excluded from all "settled" math
until the Stripe webhook clears it), `stripe_payment_intent`,
`stripe_charge_id`.

**invoice_freight_allocations** — the *collected* freight ledger: per
`(invoice, item[, component])` slice of billed freight; `amount`, `share_pct`,
`allocation_source` ('auto_proportional'/'retainer'/'deferred_billed'/manual).
Written automatically on every non-draft invoice save.

**invoice_sends** — email audit: `type` (invoice/receipt/reminder),
`recipient_email`, `subject`, `resend_message_id`, `sent_by_user_id`, `rule_key`
(reminder dedupe). **invoice_views** — client open tracking (`viewed_at`,
`user_agent`, `ip`), written by the pay-page edge function with service role.

### Money — costs

**expenses** — `project_id`, `name`, `cost`, `date`, `card`,
`expense_type` ('billable'/'passthrough'/'nonbillable'), `category`, `notes`,
`track_in_pm`, `receipt_path`/`receipt jsonb`, `po_id`, `proposal_item_id`
(legacy single-FK), resolution state (`resolved`, `status`,
`resolved_invoice_id/number`). **expense_allocations** — split an expense across
items: `expense_id`, `proposal_item_id`, `amount`, `status`,
`invoice_line_item_id` (durable link once billed), `resolved_at`.

**freight_categories** — taxonomy: `name`, `default_markup_pct` (null = project
default), `is_taxable`, `is_system`, `flat_rate` (pre-fills Log Freight Actual),
`is_fee` (revenue-only category → logging routes to `client_fees`, not costs).

**freight_charges** — *proposal-side* freight promises, polymorphic
`parent_type` ('item'/'component') + `parent_id`: `category_id`, `state`
('known'/'allowance'/'deferred'/'none'), `value_type` ('amount'/'percent'),
`value`, `markup_pct_override`.

**freight_actuals** — *cost-side* vendor freight bills: `project_id`,
`proposal_item_id` (null for splits), `proposal_component_id`,
`freight_category_id` (null = "Any", counts as primary freight), `amount`,
`date`, `vendor_id`, `invoice_reference`, `linked_expense_id` (optional P&L
mirror). **freight_actual_allocations** — split-bill slices: `freight_actual_id`,
`proposal_item_id`, `proposal_component_id`, `amount`.

**freight_settlements** — reconciliation events against an invoice: `type`
('credit_applied'/'overage_billed'/'deferred_billed'), `amount`.

**client_fees** — revenue-only charges (e.g. $35 receiving fee): `project_id`,
`proposal_item_id/component`, `freight_category_id`, `label`, `amount`,
`taxable`, `date`, `status` ('unbilled'/'billed'), `invoice_line_item_id`.
Never enters cost/reconciliation math.

### Work management

**tasks** — `project_id`, `title`, `description`, `assignee_user_id`,
`status` (todo/in_progress/blocked/done), `priority`, `due_date`,
`completed_at`, `parent_task_id` (subtasks), `proposal_item_id`, `invoice_id`,
`custom_fields jsonb` (incl. `category`), `tags text[]`, `attachments jsonb`,
`sort_order`. (`assigned_to_user_id` is a dead legacy column; `assignee_user_id`
is canonical.) Children: **task_comments** (body, mentions[], attachments,
edited_at), **task_activity** (kind + payload event log), **task_dependencies**
(blocks/blocked-by), **task_field_defs**, **task_notes** (legacy).

**time_entries** — `user_id`, `project_id` (null = internal/non-billable
clock-in), `task_id`, `description`, `started_at`, `ended_at` (**null = running
timer** — this drives cross-device sync and the "On the clock" widget),
`duration_seconds`, `billable`, `rate` (billable rate for invoicing),
`status` ('unbilled'/'billed'), `invoice_line_item_id`, `billed_at`.

**payroll_runs** — immutable finalized pay periods: `period_start/end`, `label`,
`breakdown jsonb` (per-person hours × pay_rate), `total_hours`, `total_gross`,
`paid_at`.

### Infrastructure tables

**notifications** — per-recipient (`recipient_user_id`, `type`, `message`,
`link_entity_type/id`, `payload`, `read_at`); realtime-pushed to the bell.
**activity_entries** — cross-entity feed (`entity_type/id`, `parent_type/id`,
`text`, `mentions[]`, `source`, `event_type`, `payload`, `is_locked`).
**embeddings** — pgvector chunks per entity (semantic search infrastructure).
**app_config** — key/value (e.g. reminder cron settings).

### Security model (RLS)

Helper functions (`security definer`, search_path-pinned):
`is_studio_member(studio)`, `is_studio_owner(studio)`,
`has_permission(studio, perm)` — owner short-circuits; perms map to the
`can_*` flags (`view_financials`, `record_payments`, `send_invoices`,
`manage_expenses`, `manage_members`, `run_payroll`, `edit_invoices`,
`adjust_time`).

- Most operational tables: any accepted studio member, full CRUD.
- Financial gates: invoices/line-items **SELECT** = `view_financials`,
  **writes** = `edit_invoices`; payments writes = `record_payments`; expense
  writes = `manage_expenses`; payroll + wages = `run_payroll`/owner;
  invoice_views SELECT = `view_financials`.
- Time entries: own rows (+ owner on-behalf); edits require `adjust_time` and
  `status='unbilled'`; running-timer stop/cancel carved out so timers always work.
- Sending email enforces `can_send_invoices` inside the edge function (not just UI).
- Triggers: `protect_studio_member_privileged` (non-owners can't touch
  rates/roles/flags), `protect_studio_sensitive_settings` (non-owners can't
  alter tax keys in the settings blob), owner_user_id freeze on studios.

---

## 3. Projects, proposals, and items — the deep dive

### The proposal is the spine

A project's substance lives in `S.proposals[projectId]` =
`{ spaces: [ { id, name, note, items: [...] } ], estimates: [...] }` — persisted
across `proposal_spaces` → `proposal_items` → `proposal_components`. The
proposal is **not** a quote document; it's the long-lived staging ground where
items are born, priced, approved, procured, and reconciled. Estimates snapshot
it; invoices bill from it; PM works it.

### proposal_items — every field (57)

Identity/placement: `id`, `space_id`, `sort_order`, `type`
('readymade' | 'openline' | 'constructed'), `name`, `item_code`, `room`
(legacy), `category`.

Sourcing: `vendor_id`, `vendor_contact_id`, `brand_id`, `contact` (legacy
free-text), `item_type_id` (category — drives optional per-category markup),
`po_id`.

Pricing: `net_price` (per-unit cost; constructed items derive cost from
components instead), `qty` + `qty_unit`, `allowance` (placeholder pricing),
`tax_exempt`, `bill_cost_only` (0% markup), `adjust_markup` (custom markup %),
`client_price_override` (direct "client pays $X" — beats all markup tiers;
per-unit for readymade/openline, total for constructed),
`additional_charges jsonb` (readymade add-ons, each with its own markup opts),
`group_components` (constructed: sync component statuses to the item).

Effective markup resolution: `client_price_override` → `adjust_markup` →
`item_types.default_markup_pct` → `projects.markup_pct` → 25.

Pipeline/PM: `status` (proposed → approved → ordered → … configurable pipeline),
`status_flags jsonb` (attention flags incl. "Needs Work Order"), `due_date`
("needed on site"), `invoice_phase`, `assignee_user_id`, `ordered_at`,
`lead_time_weeks_min/max`, `lead_time_start_manual`, `tracking_numbers jsonb`,
`vendor_order_number`.

Cost actuals: `cost_actual` (what was actually paid — entered via the Log Cost
Actual modal), `cost_actual_payment_method` (card), `cost_actual_meta jsonb`
(`{notes, card, orderedByUserId, loggedByUserId, loggedAt, updatedAt}`),
`additional_costs jsonb` (legacy).

Billing links: `invoice_ids uuid[]`, `invoice_line_id`, `invoice_number`,
`expense_id`, `proposal_item_origin`.

Freight: `freight_approved_snapshot jsonb` — frozen at estimate lock
(first-write-wins): the proposal-approved freight allowance for reconciliation.

Content: `notes`, `description` (see below), `files jsonb`, `links jsonb`,
`main_image_id`, `main_link_url`, `activity_log jsonb`.

### proposal_components — every field (37)

Same shape as items minus item-only concerns: `item_id`, `name`,
`component_type` ('base'/'fabric'/'shipping'/'other'…), `net_cost`, `qty` +
`qty_unit`, own `status` (+ shipping statuses for shipping components),
`due_date`, `invoice_phase`, `description`, `note` (internal, hideable from
print), `allowance`, `tax_exempt`, `bill_cost_only`, `adjust_markup`,
`client_price_override` (line total), `cost_actual` + `cost_actual_meta`,
`additional_costs`, `files/links/tracking_numbers/activity_log jsonb`,
sourcing (`vendor_id/vendor_contact_id/brand_id/item_type_id`), lead-time
fields. A constructed item's client price = Σ component line totals (qty baked
into components; the item row is qty=1/price=total everywhere downstream).

### What the "item detail page" (PM view) actually stores

The PM item detail panel renders and writes **directly onto the
proposal_items/proposal_components row** — there is no separate PM table:

- Status dropdown + status flags → `status`, `status_flags`
- Dates → `due_date`, `ordered_at`, lead-time fields
- **Cost Tracking card** → `cost_actual`, `cost_actual_payment_method`,
  `cost_actual_meta`, `vendor_order_number`, `actualFreight` (legacy field on
  the in-memory shape), plus the reconciliation strip (Collected / Actual / Δ)
  computed from invoice lines + freight allocations
- **Freight card** → reads `freight_charges`, `freight_actuals`(+allocations),
  `invoice_freight_allocations`, `freight_approved_snapshot`
- **Notes & Activity** → `activity_log jsonb` (see §4)
- Files / links / tracking → the jsonb arrays
- Work-order reflection → scans `documents` for work-order blocks tagged with
  this `proposal_item_id`

### The two note-ish fields

- **`notes`** — the *proposal note*. Placeholder text: "Rough size, design
  direction, references, 'look for cheaper options', anything you want PM to
  see while working this item…". Written in the Add/Edit Item modal and the PM
  detail panel. It renders in the proposal's expandable item rows and in
  print/PDF **with URLs stripped** (working links don't belong in client
  documents), and the PM list has a "has note" filter keyed on it. So: primarily
  an internal working note that is *also* visible on the proposal document.
- **`description`** — the client-facing descriptive copy for the item (also on
  components and invoice lines: "shown to client only if filled").

---

## 4. Mutability, history, and recoverability

**Baseline: records are mutable in place.** Editing an item/project/invoice
field overwrites the previous value in Postgres via the sync engine. There is
**no field-level audit trail or undo** for ordinary edits — if you change an
item's net price, the old price is not recoverable from the app.

What *does* preserve history, by mechanism:

| Mechanism | Coverage | Recoverable? |
|---|---|---|
| **Soft delete** (`deleted_at` on ~30 tables) | Deleted items, invoices, expenses, vendors, tasks, meetings, freight rows, … | Yes via SQL (`update … set deleted_at = null`); no UI. Loads filter `deleted_at is null`. Line items, payments, contacts-children use hard delete. |
| **Estimate snapshots** (`estimates.snapshot`) | Full deep-clone of every space/item/component at estimate save; locked (proposed/approved) estimates are immutable in-app | Yes — the proposal *as the client approved it* is always recoverable, including prices. |
| **document_versions** | Every generated document (schedules, work orders) keeps full version/revision rows with complete content | Yes — true revision history with a version picker. |
| **Activity logs** (`activity_log` jsonb on items/components; `task_activity`; `activity_entries`) | Human-readable trail: notes, @mentions, status changes, cost-actual logs ("Logged cost actual $X · card · ordered by"), substitutions, price adjustments | Descriptive history — tells you *what happened and what the values were*, but is not machine-restorable state. |
| **Substitution archive** | The ⇄ Substitute flow writes the complete original sourcing (vendor/brand/cost/qty/name) into the activity log before any edit, and anchors the settled client price via `client_price_override` | The money facts survive; old sourcing is recorded as text. |
| **`freight_approved_snapshot`** | Per-item approved freight at estimate lock, first-write-wins | Yes — reconciliation baseline can't drift. |
| **Financial append-only ledgers** | `invoice_payments`, `invoice_sends`, `invoice_views`, `freight_settlements`, `payroll_runs`, `vendor_credential_access_log`, credit `draws[]` | These are event records, not mutated state. Paid invoices are locked in the UI (§3 invoice locking); cancellation goes through an explicit refund/credit/error flow rather than deletion. |
| **localStorage mirror** (`beep_hq_v1`) | Whole `S` on the last device that saved | Incidental, transient — a forensic last resort, not a feature. |
| **Supabase PITR/backups** | Whole database | Platform-level disaster recovery. |

**Practical answer:** if you edit an item, the previous state is recoverable
only if it was captured by an estimate snapshot (client-approved prices), the
activity log (cost actuals, substitutions, notes), or a soft-deleted row.
Ordinary field edits (name, qty, net price, description, statuses) have no
undo.

---

## 5. Screens

One SPA with 14 top-level views (`showView(v)` toggles `#view-*` divs; the
sidebar is the nav). Deep state — active tab, open project/item — persists
across refresh. Plus the standalone client pay page.

| View | What it is |
|---|---|
| **Projects** (`projects`) | Card grid of projects (stage, client, totals). Entry point to everything. Default landing view. |
| **Project Detail** (`project-detail`) | The workhorse. Eight tabs: **Overview** (client card, install date, available-credit banner, quick refs), **Proposal** (spaces → items editor, estimate builder/versions, client-view toggle, print/PDF), **Project Mgmt** (PM item list with filters/search + the item detail panel: status, dates, cost tracking, freight reconciliation, notes & activity, files, links, tracking, substitution), **Address Book**, **Meetings** (date/time-stamped meeting notes), **Documents** (uploaded project files + folders + generated docs list), **Expenses** (project-scoped), **Budget** (five sub-tabs: Overview — booked/projected profit hero + credit/overage; Expenses; Time — labor profitability; Freight — per-invoice collected/actual rollups with drill-in modals; Items — cost-side mirror), **Settings** (stage/type/address/markup/tax state + jurisdictions/install date). |
| **Proposal** (`proposal`) | Standalone proposal editor for a selected project (same engine as the Proposal tab; project picker + client-view mode). |
| **Clients** (`clients`) | Client list + client cards. |
| **Contacts** (`contacts`) | Vendor-centric address book. Toolbar: search + type filter + **offerings filter** (flips to brand-focused cards showing which vendors carry each brand) + brand filter; By Company / By Person views; vendor editor with reps, brands, encrypted portal credentials. |
| **Work** (`work`) | Two tabs: **Queue** (awaiting-action roll-up: notifications, unpaid invoices, task alerts, dismissible) and **Tasks** (Asana-style: list/board/calendar/reports views, subtasks, dependencies, @mention comments, attachments, categories, assignment). |
| **Documents** (`documents`) | Cross-project generated documents + purchase orders tab. |
| **Doc Editor** (`doc-editor`) | Full-screen editor for a generated document: schedule items/rooms, work-order text blocks with images/captions/page breaks, version history, PDF export. |
| **Time** (`time`) | Timer widget (cross-device, server-backed), **On the clock** live admin strip, tabs: Summary, Full Log (filters), **Payroll** (owner/`can_run_payroll`: period gross per person, finalize & mark paid, history). |
| **Expenses** (`expenses`) | Studio-wide expense list + reports tab; receipt uploads; billable/pass-through/non-billable lifecycle into invoices. |
| **Invoices** (`invoices`) | Invoice list (project/client/status/type filters) + Reports tab (period revenue, tax by state, revenue by client/project). |
| **Invoice Builder** (`invoice-builder`) | Create/edit one invoice: pull proposal items/components, unresolved expenses, unbilled time, **unbilled fees**; freight + retainer; discounts; credits (apply project credit, per-line ◐ cover-with-credit incl. client-hidden mode); payments panel (record/Stripe); send flow (email via Resend, receipts, reminders); PDF. Locked when paid; view-only without `can_edit_invoices`. |
| **Dashboard** (`dashboard`) | Financial gate (`can_view_financials`). Four tabs: **Overview** (Right Now zone: outstanding/overdue/drafts/cash/AR pills/Top-5 + On-the-clock; This Period zone: cash revenue, expenses, booked-profit card, charts, project profitability w/ Booked vs Projected + costs-logged %, taxes by state), **P&L** (cash-basis statement), **A/R Aging** (per-client buckets), **Sales Tax** (filing-grade cash-basis report with jurisdiction drill-down + filing tracker). |
| **Settings** (`settings`) | Studio tabs: studio info/branding, Team (members, permissions, rates — owner), payment methods config, item types (+ per-category markup), freight categories (+ flat rate / fee flags), statuses & pipeline, tax states, appearance/theme, cards, invoice note presets. |
| **Pay page** (`/pay/?t=<token>`) | Public, token-gated client page: invoice render (location-grouped lines, credits, totals), payment methods per config (ACH/card via Stripe Checkout, wire/check/custom instructions), receipt state, watermark branding. |

Auth overlay (sign-in / set-password) sits above everything until a session
exists. Modals (~40 of them — item editor, cost actual, freight actual, meeting,
task, substitution delta, credit application, …) are overlay divs, not routes.
