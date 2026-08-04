# Time Tracking → Invoicing: Toggl Track vs. Bonsai — Research Report

> Researched 2026-08-03 for WORKLIST §6A (time-system overhaul, Sept 1 critical
> path). Informs reconciliation, rounding, periods, payroll, and invoice-line
> design.

The two products represent opposite architectures: **Toggl treats the invoice
as a disposable export of a report** (no billed-state on entries), while
**Bonsai treats billing status as a first-class field on every time entry**
with a full state machine. Bonsai's model is the one worth copying for BEEP
(and it matches the schema BEEP already has: `status` +
`invoice_line_item_id` + `billed_at` on `time_entries`).

## 1. Marking entries as billed/invoiced

- **Bonsai**: Every time entry carries a billing status. "Unbilled" = billable
  time not yet invoiced *or sitting on a draft invoice*. Adding hours to an
  invoice flips them to "Billed." Users can also manually override in both
  directions via "Mark as Billed" / "Mark as Unbilled" on the entry's overflow
  menu (useful for time billed outside the system). Hours can still be edited
  after being added to an invoice's timesheet.
- **Toggl**: **No entry-level billed flag at all.** The officially documented
  workaround is to add a `paid` tag to invoiced entries, then filter future
  reports with `Tags is-not paid`. Invoices are generated from reports and
  downloaded as PDFs; they are not durably linked back to the entries.
- **Locking**: Toggl has two separate lock mechanisms, neither tied to
  invoicing: (a) workspace-level "Lock time entries" — regular users can't
  add/edit/delete entries dated on or before a chosen date; (b) approved
  timesheets are locked from editing. Bonsai similarly locks timesheets to
  prevent edits, but invoicing itself doesn't lock entries.

## 2. Defining/reporting unbilled time

- **Bonsai**: Per-project **Time tab** shows unbilled entries with an "Invoice
  Unbilled Hours" button (button absent = zero unbilled hours — a nice
  affordance). Unbilled is a real query-able status, so per-project uninvoiced
  totals are native.
- **Toggl**: No native concept. "Unbilled" = billable entries minus whatever
  you've tagged as paid; you reconstruct it with report filters. No
  since-last-invoice default.

## 3. Invoice deletion behavior

- **Bonsai**: On deleting an invoice that contains billed hours, a dialog asks
  what to do with them: **(a) revert to unbilled project hours** (available
  for future billing) or **(b) delete the hours permanently** (unrecoverable).
  Document deletion itself is permanent — they recommend downloading the PDF
  first. This explicit fork is the pattern to copy.
- **Toggl**: Nothing to do — the invoice was never linked to entries. Your
  `paid` tags stay wrong until you manually remove them (a real footgun of the
  tag approach).

## 4. Rounding

- **Toggl** (paid plans only): Rounding is a **report-level toggle**, not
  stored on entries. Directions: **round up / round to nearest / round down**.
  Increments: **1, 5, 6, 10, 12, 15, 30 min, 1 hr, 4 hr**. Critically, it can
  apply to **individual entries** or to **grouped entries** (sum the group's
  raw time, then round the subtotal) — the grouped option is fairer to clients
  and worth copying.
- **Bonsai**: Rounding is chosen **at invoice-generation time** in the
  "Invoice Unbilled Hours" modal. Increments: **nearest minute, 15 min,
  30 min, 1 hour**. Original tracked time on the timesheet is never modified —
  rounding affects invoice presentation only.
- Shared principle in both: **rounding is a display/billing-time transform;
  the raw entry duration is never mutated.**

## 5. Billable vs. non-billable

- **Bonsai**: Billable flag set at entry creation or changed later via a
  Billing dropdown on the entry. Non-billable entries never appear in
  "unbilled hours" (so never reach invoices) but remain on timesheets and in
  reports for a "holistic view of all tracked time" — feeding utilization
  metrics.
- **Toggl**: Billable is a per-entry toggle (default inheritable from
  project). Only billable time carries an amount. Non-billable time still
  counts in tracked-hours totals, timesheets, and utilization — it just has $0
  revenue. Their agency guidance leans on billable-utilization-% reporting
  (billable hours ÷ total hours).

## 6. Team / payroll angle (rates + approvals)

- **Toggl** has the most explicit two-rate model:
  - **Billable rates**: cascade workspace → workspace member → project →
    project member → **task** (most granular wins).
  - **Labor costs**: a separate internal cost rate per workspace member or
    project member, visible/settable only by Admins and Project Leads, with
    **historical rate tracking**. Profitability report = billable amount −
    labor cost, sliceable by member, group, project, client, task, tag.
  - **Timesheet Approvals**: grouped entries per period become a timesheet
    with statuses (unsubmitted → submitted → approved/rejected), an audit log,
    and **locking on submit/approval** — explicitly positioned as making data
    "ready for billing, payroll, or compliance."
- **Bonsai**: **Cost rate per team member/project** vs. billable rate (project
  rates, member rates, or **rate cards** — role-based rate presets applicable
  per client/project). Labor cost = cost rate × time tracked; margin =
  billable − cost. Weekly per-member timesheets with locking, plus
  capacity-utilization columns (% of weekly capacity used). Less formal
  approval workflow than Toggl.
- Directly relevant to BEEP's Time+Payroll feature: both products confirm the
  **decoupled pay-rate/billable-rate** design (BEEP already has this), and
  Toggl's "approved timesheet = locked, payroll-ready period" maps cleanly
  onto a payroll-period concept.

## 7. Invoice line-item presentation

- **Toggl**: Line grouping = which report you started from. Summary report →
  one line per project (project name, total time, total amount). Detailed
  report → one line per time entry (entry descriptions become line text).
- **Bonsai**: Default groups time entries **by rate**; user can regroup by
  **task, service, role, or date** — totals unchanged, only line aggregation
  changes. Separately, a **timesheet attachment** with configurable columns
  (notes, task, service) can be: shown in full below the invoice, exposed as a
  client-clickable link, or hidden. The "compact line items + optional
  detailed timesheet appendix" split is an excellent pattern — clients get a
  clean invoice and full transparency without cluttering the document.

## 8. Period selection

- **Bonsai**: The Invoice Unbilled Hours modal offers **"all unbilled hours"
  (the default) or a custom date range**. Because billed-status is tracked,
  "all unbilled" naturally means "since whatever was last invoiced" without
  any date math.
- **Toggl**: Period = the report's date-range picker (this week/month, last
  week/month, custom, etc.). No "since last invoice."

## Patterns worth copying into BEEP

1. **Entry-level `billed_status` + FK to the invoice line** (Bonsai), not a
   tag or implicit date range — makes "unbilled" a query, enables the
   per-project "Invoice Unbilled Hours" button, and makes "all unbilled" the
   natural default period. (BEEP's schema already has this; the writer just
   never persisted it — see WORKLIST §6A.1.)
2. **Deletion dialog with an explicit fork**: revert hours to unbilled vs.
   discard (Bonsai). Never silently orphan or silently re-open.
3. **Manual Mark as Billed / Unbilled overrides** for out-of-band billing
   (Bonsai) — this is exactly the historical-backfill tool BEEP needs for
   BE-114-era invoices.
4. **Rounding as a billing-time transform with direction + increment, applied
   per-entry or per-group-subtotal; raw durations immutable** (Toggl's option
   set is the richer one).
5. **Two-rate model with history**: billable-rate cascade separate from
   admin-only labor-cost rates (Toggl), enabling profitability = revenue −
   labor cost.
6. **Approved timesheet = locked, payroll-ready period** with statuses and
   audit log (Toggl) — the natural bridge to BEEP's payroll-period ask
   (§6A.5).
7. **Clean invoice lines + optional timesheet appendix** (full/link/hidden)
   with configurable grouping (Bonsai) — pairs perfectly with the "Project
   Hours, [User's name]" clean-line requirement (§6A.4): simple line, detail
   in the appendix if ever wanted.
8. Non-billable time: excluded from invoicing and revenue by the flag, but
   always present in timesheets/utilization/payroll views (both products).

## Sources

- Toggl: Creating Invoices — https://support.toggl.com/en-us/article/creating-invoices-in-toggl-track-1irsvlv/
- Toggl: Rounding — https://support.toggl.com/en/articles/10750260-rounding
- Toggl: Billable rates — https://support.toggl.com/en/articles/2216967-billable-rates
- Toggl: Labor Costs — https://support.toggl.com/en/articles/9847544-labor-costs
- Toggl: Profitability Report — https://support.toggl.com/profitability-report
- Toggl: Timesheet Approvals — https://support.toggl.com/overview-of-timesheet-approvals
- Toggl: Timesheet statuses — https://support.toggl.com/en/articles/8473442-what-do-the-different-timesheet-statuses-mean
- Toggl: Locking time entries — https://support.toggl.com/en/articles/2206898-locking-time-entries
- Bonsai: Invoicing your tracked time — https://help.hellobonsai.com/en/articles/1898575-invoicing-your-tracked-time
- Bonsai: Rounding time entries on invoices — https://help.hellobonsai.com/en/articles/7050494-rounding-time-tracking-entries-on-invoices
- Bonsai: Tracking time internally — https://help.hellobonsai.com/en/articles/2548737-tracking-time-internally-with-bonsai
- Bonsai: Timesheets — https://help.hellobonsai.com/en/articles/9073093-tracking-time-with-timesheets
- Bonsai: Rate Cards — https://help.hellobonsai.com/en/articles/10682552-rate-cards
- Bonsai: Budgeting & Profitability — https://www.hellobonsai.com/budgeting-profitability
- Bonsai: Timesheets for Teams — https://www.hellobonsai.com/timesheets
