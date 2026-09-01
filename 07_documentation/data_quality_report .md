# Data Quality Report
Collections Analytics — CredResolve Assignment

## Summary

Seven material data-quality issues were found. Two of them — duplicate
payments and reversal netting — are large enough on their own to fabricate
the reported "11% improvement." All are detailed below with detection method,
treatment, and quantified business impact.

| # | Issue | Detection method | Treatment | Business impact |
|---|---|---|---|---|
| 1 | Duplicate payment rows | Full-row duplicate check on `payments.csv` (all columns except `payment_id`) | Drop, keep first occurrence | 486 rows removed |
| 2 | Retry-duplicate payments (same real payment, new `payment_id`) | Grouped by `payment_reference`; found 8,424 rows sharing a reference, 2,033 references with >1 `SUCCESS` row | Keep earliest `SUCCESS` per `payment_reference` | Removes **12.7%** of reported SUCCESS amount |
| 3 | Reversed payments counted as recovery | Checked `payment_status` distribution | Net `REVERSED` amount out of recovery totals | Removes a further ₹94.7M (further drop) |
| 4 | Agent identity fragmentation | `agents.csv`: 30,000 rows, only 1,000 unique `agent_id`; `employee_code` has 1,099 unique values (not 1:1); `agent_name` has only 10 unique values company-wide | `agent_id` used as the sole identity key; latest snapshot per agent kept | Any analysis keyed on `employee_code` or `agent_name` is unreliable |
| 5 | Borrower history stored as overwrite-style duplicates | `borrowers.csv`: 30,600 rows vs 11,015 unique `borrower_id` | Keep latest row per `borrower_id` by `updated_at` | 19,585 stale snapshot rows removed |
| 6 | Disposition-code drift across schema versions | `call_dispositions.disposition_version` has `legacy`/`v1`/`v2`, each using different code strings for the same event (`PROMISE_TO_PAY` vs `PTP`) | Metrics computed from the dedicated `promises_to_pay` table, not from disposition-code string matching | Avoids ~50% undercount of PTP-based metrics in affected periods |
| 7 | Mixed timezones with no normalization | `calls.timezone` and `accounts.timezone` are split ~evenly across `UTC` / `Asia/Kolkata` / `Asia/Dubai` | All time-of-day analysis normalizes to IST before bucketing by hour/day | Prevents misclassifying ~2/3 of events into the wrong local hour or day |

## Checks that did NOT find a problem (equally important to report)

- **Portfolio mix (risk segment, DPD) of accounts actually worked** is flat
  month-over-month (~25% per segment, DPD ~56 throughout Jan–Jul). The
  business did not switch to an easier portfolio.
- **Denominator manipulation:** the `daily_targeting.status` mix
  (`QUEUED`/`CONTACTED`/`SKIPPED`/`EXPIRED`) stays proportional every month —
  no evidence unsuccessful accounts are being dropped from the population
  used to calculate conversion rates.
- **Agent headcount and tenure:** stable at 1,000 active agents every month,
  tenure aging organically (~+30 days/month) — no unusual hiring surge or
  attrition event.
- **Vendor telephony schema versions** (`v1`/`v2`/`v3`) exist per-vendor but
  do not show a clean cutover date correlated with the recovery trend.

## Coverage caveat

The brief describes "approximately 12 months" of data. The operational
tables (`calls`, `payments`, `call_attempts`, `promises_to_pay`,
`daily_targeting`) actually span **January 1 – August 12, 2026 (~7.5
months)**, with August truncated mid-month. All month-on-month analysis in
this submission uses the seven **complete** months (Jan–Jul) and excludes
August to avoid a spurious "collapse" driven purely by a partial month.

## Golden dataset row-count waterfall

| Table | Raw rows | Golden rows | Removed | Reason |
|---|---:|---:|---:|---|
| borrowers | 30,600 | 11,015 | 19,585 | duplicate snapshot rows |
| agents | 30,000 | 1,000 (unique entities) | 29,000 snapshot rows collapsed | identity resolution |
| accounts | 30,000 | 30,000 | 0 | clean |
| payments | 25,500 | 22,819 rows / 15,350 unique successful payments | 486 exact dupes + 2,195 retry-dupes | dedup |

Net recovery impact: naive (as-reported) SUCCESS total = **₹1,341.5M**.
Golden net recovery (deduped, reversals netted) = **₹1,055.2M** — a
**21.3% reduction** from the number currently being reported on.
