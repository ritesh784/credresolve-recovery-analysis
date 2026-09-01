-- ============================================================================
-- GOLDEN DATASET CONSTRUCTION
-- Collections Analytics — CredResolve Assignment
-- Target: any standard warehouse (Postgres/Snowflake/BigQuery syntax; adjust
-- date functions as needed for your engine)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. GOLDEN BORROWERS
-- Problem: borrowers.csv has 30,600 raw rows but many represent the same
-- borrower_id snapshotted multiple times (history-as-overwrite pattern).
-- Fix: keep the latest row per borrower_id by updated_at.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_borrowers AS
SELECT *
FROM (
    SELECT
        b.*,
        ROW_NUMBER() OVER (
            PARTITION BY borrower_id
            ORDER BY updated_at DESC
        ) AS rn
    FROM raw.borrowers b
) t
WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- 2. GOLDEN AGENTS
-- Problem: agents.csv has 30,000 rows but only 1,000 unique agent_id values.
-- employee_code is NOT 1:1 with agent_id (1,099 unique codes for 1,000 agents
-- -- agents were re-issued employee codes over time). agent_name has only 10
-- distinct values across the whole company -- names must NEVER be used as an
-- identity key.
-- Fix: agent_id is the single source-of-truth identity key. Keep latest
-- snapshot per agent_id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_agents AS
SELECT *
FROM (
    SELECT
        a.*,
        ROW_NUMBER() OVER (
            PARTITION BY agent_id
            ORDER BY updated_at DESC
        ) AS rn
    FROM raw.agents a
) t
WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- 3. GOLDEN ACCOUNTS  (no material duplication found; account_id is clean)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_accounts AS
SELECT DISTINCT ON (account_id) *
FROM raw.accounts
ORDER BY account_id;

-- ----------------------------------------------------------------------------
-- 4. GOLDEN PAYMENTS  (the most important cleaning step in this assignment)
--
-- Issues found:
--   a) 486 rows are exact full-row duplicates (same values, different
--      payment_id) -- classic ingestion/retry duplication.
--   b) 2,195 additional rows share a payment_reference with an existing
--      SUCCESS row -- i.e. the SAME real-world payment was logged twice
--      (e.g. webhook retried, gateway callback duplicated) under a new
--      payment_id. Keeping all of them inflates recovered amount by ~12.7%.
--   c) REVERSED payments (chargebacks/failed clearing) were being counted as
--      recovery in the naive "sum of SUCCESS" logic used for headline
--      reporting even though the money did not durably land. These must be
--      netted OUT.
--
-- Net effect: golden recovery is ~21.3% LOWER than the naive number the
-- business has been reporting on.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_payments_deduped AS
SELECT *
FROM (
    SELECT
        p.*,
        ROW_NUMBER() OVER (
            PARTITION BY account_id, borrower_id, amount, event_at,
                         payment_status, payment_method, provider_id
            ORDER BY payment_id
        ) AS full_row_rn
    FROM raw.payments p
) t
WHERE full_row_rn = 1;   -- drops exact full-row duplicates

CREATE OR REPLACE TABLE golden_payments AS
SELECT * FROM (
    -- one row per real successful payment (earliest instance of a reference)
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY payment_reference ORDER BY event_at ASC
    ) AS ref_rn
    FROM stg_payments_deduped
    WHERE payment_status = 'SUCCESS'
) s WHERE ref_rn = 1

UNION ALL

SELECT *, NULL AS ref_rn
FROM stg_payments_deduped
WHERE payment_status <> 'SUCCESS';

-- Net recovery view: SUCCESS minus REVERSED, by month
CREATE OR REPLACE VIEW v_monthly_net_recovery AS
SELECT
    DATE_TRUNC('month', event_at) AS month,
    SUM(CASE WHEN payment_status = 'SUCCESS'  THEN amount ELSE 0 END)
  - SUM(CASE WHEN payment_status = 'REVERSED' THEN amount ELSE 0 END) AS net_recovery
FROM golden_payments
GROUP BY 1;

-- ----------------------------------------------------------------------------
-- 5. DISPOSITION CODE HARMONIZATION
-- Problem: disposition_code strings changed across schema versions
-- (e.g. 'PROMISE_TO_PAY' in v1 vs 'PTP' in legacy/v2 mean the same event).
-- Any metric built on raw disposition_code strings without this mapping will
-- silently undercount in whichever period used the "other" code.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_call_dispositions AS
SELECT
    d.*,
    CASE
        WHEN disposition_code IN ('PROMISE_TO_PAY','PTP')        THEN 'PTP'
        WHEN disposition_code IN ('PTP_BROKEN')                  THEN 'PTP_BROKEN'
        WHEN disposition_code IN ('NO_CONTACT')                  THEN 'NO_CONTACT'
        WHEN disposition_code IN ('WRONG_NUMBER')                THEN 'WRONG_NUMBER'
        WHEN disposition_code IN ('CALLBACK')                    THEN 'CALLBACK'
        WHEN disposition_code IN ('DISPUTE')                     THEN 'DISPUTE'
        WHEN disposition_code IN ('PAID')                        THEN 'PAID'
        WHEN disposition_code IN ('REFUSED')                     THEN 'REFUSED'
        ELSE disposition_code
    END AS disposition_code_normalized
FROM raw.call_dispositions d;
