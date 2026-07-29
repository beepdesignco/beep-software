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
| 3.5.2 Notifications overhaul | NEXT UP |
| 3.1 status_kind mapping | Queued (medium — touches automation hooks) |
| 3.3 Cost-side currency/FX | Queued (BIG — pricing-chain scope, not "small debt") |
| 4.1–4.8 Design features | Queued in order; 4.1 item specs is the keystone |
| 5 SaaS gaps | Parked until §4 + pricing decision |

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
