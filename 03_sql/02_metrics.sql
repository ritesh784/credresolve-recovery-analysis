-- ============================================================================
-- METRIC DEFINITIONS & ANALYTICAL QUERIES
-- Run against the golden_* tables created in 01_golden_dataset.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- METRIC 1: Contact Rate = ANSWERED calls / total calls
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_contact_rate AS
SELECT
    DATE_TRUNC('month', event_at) AS month,
    100.0 * SUM(CASE WHEN call_status = 'ANSWERED' THEN 1 ELSE 0 END) / COUNT(*) AS contact_rate_pct
FROM raw.calls
GROUP BY 1;

-- ----------------------------------------------------------------------------
-- METRIC 2: PTP Rate = PTPs created / answered calls in the month
-- (uses promises_to_pay table directly -- NOT disposition_code strings --
--  to avoid the code-drift problem documented above)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ptp_rate AS
WITH answered AS (
    SELECT DATE_TRUNC('month', event_at) AS month, COUNT(*) AS answered_calls
    FROM raw.calls WHERE call_status = 'ANSWERED' GROUP BY 1
),
ptps AS (
    SELECT DATE_TRUNC('month', event_at) AS month, COUNT(*) AS ptp_count
    FROM raw.promises_to_pay GROUP BY 1
)
SELECT a.month, 100.0 * p.ptp_count / a.answered_calls AS ptp_rate_pct
FROM answered a JOIN ptps p USING (month);

-- ----------------------------------------------------------------------------
-- METRIC 3: PTP Kept Rate = KEPT / (KEPT + BROKEN), resolved promises only
-- (OPEN/CANCELLED are excluded -- they have not resolved yet and would bias
--  the rate if included as failures)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ptp_kept_rate AS
SELECT
    DATE_TRUNC('month', event_at) AS month,
    100.0 * SUM(CASE WHEN status = 'KEPT' THEN 1 ELSE 0 END)
          / SUM(CASE WHEN status IN ('KEPT','BROKEN') THEN 1 ELSE 0 END) AS ptp_kept_rate_pct
FROM raw.promises_to_pay
GROUP BY 1;

-- ----------------------------------------------------------------------------
-- METRIC 4: Recovery Rate = net recovery / accounts actually worked that month
-- (raw ₹ recovered is meaningless on its own -- it must be normalized by the
--  size of the population being worked, or portfolio growth alone inflates it)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_recovery_per_account AS
WITH worked AS (
    SELECT DATE_TRUNC('month', target_date) AS month, COUNT(DISTINCT account_id) AS accounts_worked
    FROM raw.daily_targeting GROUP BY 1
)
SELECT
    r.month,
    r.net_recovery,
    w.accounts_worked,
    r.net_recovery / NULLIF(w.accounts_worked, 0) AS recovery_per_account
FROM v_monthly_net_recovery r
JOIN worked w USING (month);

-- ----------------------------------------------------------------------------
-- METRIC 5: Recovery per Agent-Hour
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_recovery_per_agent_hour AS
WITH hours AS (
    SELECT
        DATE_TRUNC('month', login_at) AS month,
        SUM(EXTRACT(EPOCH FROM (logout_at - login_at)) / 3600.0) AS agent_hours
    FROM raw.agent_sessions
    WHERE logout_at IS NOT NULL
    GROUP BY 1
)
SELECT r.month, r.net_recovery, h.agent_hours,
       r.net_recovery / NULLIF(h.agent_hours, 0) AS recovery_per_agent_hour
FROM v_monthly_net_recovery r
JOIN hours h USING (month);

-- ----------------------------------------------------------------------------
-- ANALYTICAL QUERY A: Naive (as-currently-reported) vs Golden MoM comparison
-- -- this is the query that resolves the "is 11% real" question
-- ----------------------------------------------------------------------------
WITH naive AS (
    SELECT DATE_TRUNC('month', event_at) AS month, SUM(amount) AS naive_recovery
    FROM raw.payments WHERE payment_status = 'SUCCESS' GROUP BY 1
)
SELECT
    n.month,
    n.naive_recovery,
    g.net_recovery AS golden_recovery,
    100.0 * (n.naive_recovery - LAG(n.naive_recovery) OVER (ORDER BY n.month))
          / LAG(n.naive_recovery) OVER (ORDER BY n.month) AS naive_mom_pct,
    100.0 * (g.net_recovery - LAG(g.net_recovery) OVER (ORDER BY n.month))
          / LAG(g.net_recovery) OVER (ORDER BY n.month) AS golden_mom_pct
FROM naive n
JOIN v_monthly_net_recovery g USING (month)
WHERE n.month BETWEEN '2026-01-01' AND '2026-07-31'   -- exclude partial August
ORDER BY n.month;

-- ----------------------------------------------------------------------------
-- ANALYTICAL QUERY B: Duplicate payment detection (Forensics item A)
-- ----------------------------------------------------------------------------
SELECT payment_reference, COUNT(*) AS n_rows,
       COUNT(*) FILTER (WHERE payment_status = 'SUCCESS') AS n_success,
       SUM(amount) FILTER (WHERE payment_status = 'SUCCESS') AS total_success_amount
FROM raw.payments
GROUP BY payment_reference
HAVING COUNT(*) FILTER (WHERE payment_status = 'SUCCESS') > 1
ORDER BY n_success DESC;

-- ----------------------------------------------------------------------------
-- ANALYTICAL QUERY C: Agent identity fragmentation check (Forensics item E)
-- ----------------------------------------------------------------------------
SELECT agent_id, COUNT(DISTINCT employee_code) AS n_employee_codes
FROM raw.agents
GROUP BY agent_id
HAVING COUNT(DISTINCT employee_code) > 1;

-- ----------------------------------------------------------------------------
-- ANALYTICAL QUERY D: Portfolio mix stability check (Forensics item F)
-- Segment mix of the ACTIVE population being called, by month -- flat mix
-- across months rules out "we just switched to an easier portfolio"
-- ----------------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', c.event_at) AS month,
    a.risk_segment,
    COUNT(*) AS calls,
    100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('month', c.event_at)) AS pct_of_month
FROM raw.calls c
JOIN golden_accounts a USING (account_id)
GROUP BY 1, 2
ORDER BY 1, 2;
