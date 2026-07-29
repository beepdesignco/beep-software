# BEEP HQ — Sales Tax Audit

> Read-only audit, 2026-07-29. Per the work-list §2 mandate: **fixes proposed,
> none implemented.** Code findings verified against source (file:line refs);
> data findings queried from the production database. States in scope:
> Mississippi, Louisiana, Georgia. Purchasing is on resale certificate ~99.5%.

---

## Executive summary

The tax core is **structurally sound**: one authoritative aggregate formula
(taxable base × project rate), correct pre-tax discount handling, correct
post-tax credit semantics, correct client-hidden-pair filing math, correct
pending-ACH exclusion, and every report surface now runs through one shared
cash-basis engine.

Seven defects found, ranked below. **One is HIGH: refunds retroactively erase
the entire sale from every tax period — including months already filed** —
instead of posting a negative in the refund period. Two compliance-posture
gaps need CPA input (LA parish structure, exemption certificates). Georgia is
registered but entirely unconfigured in the app.

---

## 1. Where tax is computed

Four copies of the invoice formula + separate proposal/estimate engines. All
compute on an **aggregate taxable base × rate** — never per-line — so there is
no per-line rounding drift. The authoritative stored `inv.tax` is an unrounded
float; rounding happens only at display (`fmt()`).

| # | Path | Role | Formula location |
|---|---|---|---|
| A1 | `recalcInvoice()` | Builder **display** | index.html:32688 |
| A2 | `saveInvoiceFromBuilder()` | **Persisted** values | :34472 (tax at :34510) |
| A3 | `recalcStoredInvoiceTotals()` | Headless recompute (expense sync, state cascade) | :28467 |
| A4 | `calcProposalTotals()` | Proposals | :20511 (tax at :20576) |
| A5 | `recalcEstimate()` / `saveEstimate()` / `printEstimate()` | Estimates (+ per-line "estimation lines" tax) | :21008 / :21100 / :21370 |

**Verified consistent:** A2 ≡ A3 token-for-token; A4 ↔ A5 ↔ estimate PDF agree
(PDF renders snapshotted numbers, no recompute); invoice PDF & pay page render
stored `inv.tax`, no recompute.

**Verified divergent (Defect #5):** A1 lacks the `Math.max(0, …)` clamp A2 has.
When a *taxable* credit/negative line exceeds taxable sales, the builder's Tax
row shows $0 but its grand total silently subtracts the negative tax — while
the saved total clamps correctly. Display-only, rare trigger, filed number is
right.

Core shape (A2, the persisted one):

```
taxableAmt = Σ taxable lines + taxable credits(−) 
           + freight (if inv.freightTaxable)
           + min(adjacentTaxableSnapshot, adjacent)
tax   = max(0, (taxableAmt − discountShareOfTaxable) × proj.taxRate/100)
ccFee = (afterDiscount + tax) × ccPct/100        ← post-tax, never taxed
total = subtotal + freight + adjacent − discount + credits + tax + ccFee
```

---

## 2. Rate resolution

**Destination-based:** the rate comes from the **project's** `state`/`tax_rate`
(the ship-to), not the studio address. `studios.settings.tax_states[]` is a
seeding library only. Reports group by `proj.state` (`getInvoiceStateName`,
:36673).

**Flow:** project settings state picker → seeds `tax_rate` +
`taxFreight`/`timeTaxable` from the configured state (:26771) → optional
jurisdiction checkboxes sum `rateComponents` into the rate field (:26805) →
saved to `projects.tax_rate`. Issued invoices snapshot `inv.taxRate`; the
state-edit cascade updates **drafts only** (:26695, by design).

**Defect #2 — rate/jurisdiction drift is possible:** `tax_rate` and
`settings.jurisdictions[]` are stored independently (:19921 vs :19930). The
sum is recomputed only on a live checkbox toggle — deliberately *not* on
modal open (:19899) — and the cascade pushes the flat state rate, never a
jurisdiction re-sum (:26713). Only jurisdiction *names* are stored, not the
rates they contributed, so a stored rate's derivation isn't auditable.

**No state set:** rate 0, tax 0, payments bucket under "Unassigned" in reports.

**No rate-verification timestamp exists** anywhere (when was 10% last checked
against LA reality? unknowable from data).

---

## 3. Taxability flags — end to end

| Flag | Set | Read | Effect |
|---|---|---|---|
| `proposal_items.tax_exempt` (+component) | item/component editor | proposal math :20533+; seeds invoice line `taxable` (:32030/:32071) | excludes item + its freight/adjacent from base |
| `projects.tax_freight` vs `invoices.freight_taxable` | project settings / builder checkbox | proposals use project flag; **invoices use the invoice flag** (:32720) | invoice-level wins; seeded from project at creation (:32834), independent after |
| `freight_categories.is_taxable` + `adjacent_charges_taxable_amount` | category editor | gated `cat.isTaxable && proj.taxFreight`, snapshotted at :32153 | `taxableAmt += min(snapshot, adjacent)` |
| `projects.time_taxable` | project settings | stamped onto billed time lines at bill time (:39703) | line freezes the project flag (MS: true, LA: false — configured) |
| `client_fees.taxable` | fee category `is_taxable` | seeds fee line `taxable` (:29343) | per-line gate |
| `invoice_line_items.taxable` | per-line checkbox (manual lines default true) | all three invoice calcs | the authoritative gate |
| CC fee | builder `%` field | :32743/:34513 | **post-tax surcharge, never in the base** (see compliance note) |

---

## 4. Edge cases — behavior verified with worked examples

1. **Discounts are pre-tax (correct).** % discount reduces the taxable base
   proportionally ($1,000 base, 10% off, 7% → tax $63). Flat discount reduces
   the base by `min(discount, taxableAmt)` — floors at 0, never negative-taxes.
2. **Credit lines are post-tax (correct, by design).** Always `taxable:false`;
   they lower the balance, never the tax. The only base-reducing mechanism is
   a *taxable negative line* (the substitution flow's "credit memo" route) —
   deliberately.
3. **Client-hidden pairs file correctly.** Hidden sale line stays taxable →
   stored/filed `inv.tax` includes its $7 per $100; the covering credit is
   non-taxable and nets the balance; client-facing surfaces subtract the
   hidden portion for display only. Blocked under % discounts (good guard).
4. **Refunds — broken (Defect #1, HIGH).** Refund pushes a negative payment
   *and flips the invoice to `cancelled`* (:35156/:35170). The report skips
   cancelled invoices entirely (:36690) — so the negative never posts, and the
   original collected tax **vanishes retroactively from the period it was
   filed in**. Any refund that crosses a filing period silently rewrites a
   filed month.
5. **Pending ACH excluded until settled (correct)** — `if (p.pending) return`
   (:36700), mirrored in the pay-page edge function.
6. **Tariffs** are now a freight category ("Tariffs"), taxed iff category
   `is_taxable` AND project `taxFreight`; legacy estimate tariff lines carry
   their stored flag.
7. **Billed hours** inherit the project's `time_taxable` at bill time, frozen
   on the line.

---

## 5. Report integrity

- **All surfaces cash-basis via one engine** (`buildSalesTaxReport` →
  `allocatePaymentToBuckets` → `computeInvoiceTaxBuckets`): Dashboard Tax tab,
  Overview taxes-by-state, P&L income split, Invoices→Reports. No accrual
  leakage remains.
- **Defect #4 (MEDIUM):** buckets back-solve `taxable = tax/rate` (:36650)
  trusting stored `tax`/`taxRate` consistency; there is no cross-check against
  the actual taxable line sum. A stored inconsistency yields a wrong
  taxable-sales figure with no guardrail.
- **Defect #3 (MEDIUM):** the filing tracker stores *date-only* records
  (`markFilingFiled` prompts only for a date, :36833) — no filed amount, no
  reconciliation against computed collected tax. It's a deadline checkbox, not
  a reconciliation.

---

## 6. State-specific findings (live data, queried 2026-07-29)

### Louisiana — the priority check ⚠

- Config: **one flat component "Louisiana base: 10%"** — no parish structure.
- The one LA project (New Orleans — Murdock Residence, 1 sent invoice) runs on
  flat `tax_rate = 10.00`, `jurisdictions = null`.
- Consequence: the report **cannot produce the state-vs-parish split LA
  returns require**. The 10% *total* may be approximately right for Orleans
  Parish, but its composition is unrecorded — and LA's state portion changed
  to 5% in Jan 2025, so the flat number's provenance is unverifiable.
- The `jurisdictions[]` machinery is the right shape for parishes; it is
  simply unpopulated.

### Georgia — the clean test ⚠

- **No Georgia entry exists in `tax_states` at all**, despite registration.
  The first GA project would seed nothing and compute $0 tax.
- No GA project exists yet, so nothing is currently wrong — this is a
  pre-flight gap. Per the work list: configure GA (state + county/local
  components) and verify end-to-end **in staging** before any live GA project.

### Mississippi — largely clean

- All five MS projects: flat 7% matching the state config. Design hours set
  taxable in MS (`timeTaxable: true`) and non-taxable in LA — confirm with CPA
  that both stances are intended.
- **MS resale number is blank** in settings (LA's is filled: 2784360-001-400).

### Resale posture — clean ✓

- **Zero** `proposal_items` rows with `tax_exempt = true` across the entire
  system. Consistent with resale purchasing: every sale is taxed; nothing to
  explain to an auditor.
- "Tax paid at purchase AND charged to client" (~0.5% case): the schema
  **cannot express** tax-paid-at-purchase — expenses/cost actuals have no
  tax-paid field — so these cases are invisible to the system. Identifying
  them today means reading vendor invoices. Gap noted; likely CPA-workflow
  rather than software.

### Gaps confirmed, flagged for CPA (not built, per mandate)

- **Exemption certificates:** `clients` has no exemption status or certificate
  storage. Commercial/nonprofit clients claiming exemption need a certificate
  on file; today that would be a free-text note at best.
- **Real property vs TPP:** installed millwork/built-ins on commercial jobs
  (Bar Nero) may be improvements to real property, changing taxability of
  materials and labor. The app has **no concept of this distinction** — every
  line is TPP. Flagged for CPA guidance; do not build speculatively.
- **CC surcharge is never in the taxable base** — may itself be taxable in
  some jurisdictions (LA worth checking).

### Live-data inconsistencies

- **"Test Project" (MS) has real settled payments** — $4.21 collected incl.
  $0.21 tax — polluting cash-basis reports. Recommend cancelling/removing its
  invoices (owner action).
- Filing tracker: **0 filings recorded** — the feature is unused, so no
  filed-vs-collected reconciliation trail exists for any past period.

---

## 7. Ranked defects & proposed fixes (NONE implemented)

| # | Sev | Defect | Proposed fix |
|---|---|---|---|
| 1 | **HIGH** | Refund cancels the invoice → report drops the *entire* sale from all periods, incl. filed ones; negative payment never posts | Report engine: include cancelled invoices' **settled payment history** (positive + negative) so the original sale stays in its filed period and the refund posts as negative collected tax in the refund period. Alternative: a distinct `refunded` status that reports include. Needs a filed-periods regression check before shipping. |
| 2 | MED | `tax_rate` ↔ `jurisdictions[]` drift; derivation unauditable | Store `{name, rate}` per selected jurisdiction at save; on project-settings open, surface a non-blocking warning when `tax_rate ≠ Σ stored jurisdiction rates`; cascade re-sums jurisdictions instead of pushing the flat state rate. |
| 3 | MED | Filing tracker records date only; no reconciliation | Add filed-amount to `markFilingFiled` prompt + store computed collected tax for the period at filing time; render filed-vs-computed delta on the tracker. |
| 4 | MED | Reports back-solve taxable base from `tax/rate` with no cross-check | Add a per-invoice consistency check (recompute taxable line sum, compare, badge discrepancies on the tax report) — diagnostic surface, not silent correction. |
| 5 | LOW | Builder display omits negative-tax clamp (A1 vs A2) | Add `Math.max(0, …)` to `recalcInvoice` to match the save path. One line. |
| 6 | LOW | Estimate PDF omits the adjacent-charges row it taxes | Add the row to `printEstimate` totals when `adjacentCharges > 0`. |
| 7 | LOW | Pay page/edge fn default CC fee to 3.5% when stored 0 | Treat `0` as an explicit value (`?? 3.5` semantics instead of `\|\| 3.5`). |

**Configuration actions (owner/CPA, no code):** populate LA parish
`rateComponents` + project jurisdictions with CPA-verified rates; add the
Georgia state config (then staging test); fill the MS resale number; start
using the filing tracker; clean the Test Project payments; CPA questions —
LA state-rate composition of the current 10%, MS/LA hours-taxability stances,
CC-surcharge taxability, real-property treatment for commercial installs,
exemption-certificate process.
