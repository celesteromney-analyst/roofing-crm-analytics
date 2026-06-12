-- ============================================================
-- SUMMIT ROOFING — ANALYSIS QUERIES
-- Microsoft SQL Server (T-SQL)
-- ============================================================
-- Author:   Portfolio Project
-- Version:  1.0
--
-- PURPOSE:
--   Business intelligence queries answering key questions
--   raised by the roofing company owner. Run after
--   01_schema.sql and 02_etl.sql have been executed.
--
-- SECTIONS:
--   1. Pipeline Health
--   2. Sales Rep Performance
--   3. Insurance Company Rankings
--   4. Insurance Agent Rankings
--   5. Lead Source Analysis
--   6. Referral Origin Analysis
--   7. Ad Hoc Diagnostic Queries
--
-- KEY METRIC DEFINITIONS:
--   Closed Revenue:       Contract total on Closed jobs only
--   Pipeline Value:       Contract total on Approved +
--                         Invoiced + Completed jobs
--   Stuck Revenue:        Contract total on Invoiced +
--                         Completed only (finished but not
--                         marked Closed in CRM)
--   Raw Close Rate:       Closed / (Closed + all Dead)
--   Adjusted Close Rate:  Closed / (Closed + Dead excluding
--                         No Damage) — removes outcomes
--                         outside rep control
--   Approval Rate:        Reached Approved or beyond /
--                         total leads
-- ============================================================

USE roofing_crm;
GO


-- ============================================================
-- SECTION 1: PIPELINE HEALTH
-- ============================================================

-- ------------------------------------------------------------
-- 1a. Current pipeline value by milestone
--     Shows where money is sitting across the pipeline.
--     Key finding: large Approved balance indicates
--     significant contracted work awaiting completion.
-- ------------------------------------------------------------
SELECT
    current_milestone,
    COUNT(lead_id)          AS job_count,
    SUM(contract_total)     AS total_contract_value,
    AVG(contract_total)     AS avg_contract_value
FROM leads
GROUP BY current_milestone
ORDER BY CASE current_milestone
    WHEN 'Unassigned Lead' THEN 1
    WHEN 'Assigned Lead'   THEN 2
    WHEN 'Prospect'        THEN 3
    WHEN 'Approved'        THEN 4
    WHEN 'Invoiced'        THEN 5
    WHEN 'Completed'       THEN 6
    WHEN 'Closed'          THEN 7
    WHEN 'Dead'            THEN 8
END;
GO


-- ------------------------------------------------------------
-- 1b. Revenue summary — closed vs pipeline vs total committed
--     Quick sanity check and executive summary number.
-- ------------------------------------------------------------
SELECT
    SUM(CASE WHEN current_milestone = 'Closed'
             THEN contract_total ELSE 0 END)            AS closed_revenue,
    SUM(CASE WHEN current_milestone
             IN ('Approved','Invoiced','Completed')
             THEN contract_total ELSE 0 END)            AS pipeline_value,
    SUM(CASE WHEN current_milestone
             IN ('Approved','Invoiced','Completed','Closed')
             THEN contract_total ELSE 0 END)            AS total_committed_revenue
FROM leads;
GO


-- ------------------------------------------------------------
-- 1c. Stuck revenue by sales rep
--     Jobs in Invoiced or Completed — work is done but
--     CRM milestone has not been updated to Closed.
--     Key finding: significant revenue hidden from standard
--     reporting due to this process gap.
-- ------------------------------------------------------------
SELECT
    sr.full_name            AS rep_name,
    COUNT(*)                AS stuck_jobs,
    SUM(l.contract_total)   AS stuck_revenue
FROM leads l
INNER JOIN sales_reps sr ON l.rep_id = sr.rep_id
WHERE l.current_milestone IN ('Invoiced', 'Completed')
GROUP BY sr.full_name
ORDER BY stuck_revenue DESC;
GO


-- ------------------------------------------------------------
-- 1d. Pipeline timing by sales rep
--     Average days spent in each pipeline stage per rep.
--     Zeros excluded from averages — only stages actually
--     passed through are counted.
--     Use to identify where leads are getting stuck.
-- ------------------------------------------------------------
SELECT
    sr.rep_id,
    sr.full_name            AS sales_rep,
    AVG(CASE WHEN pt.lead_days > 0
             THEN pt.lead_days END)                     AS avg_lead_days,
    AVG(CASE WHEN pt.prospect_days > 0
             THEN pt.prospect_days END)                 AS avg_prospect_days,
    AVG(CASE WHEN pt.approved_days > 0
             THEN pt.approved_days END)                 AS avg_approved_days,
    AVG(CASE WHEN pt.lead_to_approved_days > 0
             THEN pt.lead_to_approved_days END)         AS avg_lead_to_approved_days,
    AVG(CASE WHEN pt.lead_to_closed_days > 0
             THEN pt.lead_to_closed_days END)           AS avg_lead_to_closed_days,
    AVG(CASE WHEN pt.lead_to_dead_days > 0
             THEN pt.lead_to_dead_days END)             AS avg_lead_to_dead_days
FROM sales_reps sr
LEFT JOIN leads l       ON sr.rep_id  = l.rep_id
LEFT JOIN pipeline_timing pt ON l.lead_id = pt.lead_id
GROUP BY sr.rep_id, sr.full_name;
GO


-- ============================================================
-- SECTION 2: SALES REP PERFORMANCE
-- ============================================================

-- ------------------------------------------------------------
-- 2a. Rep close rates — raw and adjusted
--     Two CTEs separate raw calculations from rate formulas.
--     Adjusted rate excludes No Damage dead leads —
--     rep had no control over insurance company decision.
--     Pipeline value and insurance/referral split included
--     to give full performance context.
-- ------------------------------------------------------------
WITH rep_calculations AS (
    SELECT
        sr.rep_id,
        sr.full_name                                    AS rep_name,
        COUNT(l.lead_id)                                AS total_leads,

        COUNT(CASE WHEN l.current_milestone = 'Closed'
                   THEN 1 END)                          AS closed_count,
        COUNT(CASE WHEN l.current_milestone = 'Dead'
                   THEN 1 END)                          AS dead_count,
        COUNT(CASE WHEN l.dead_lead_reason = 'No Damage'
                   THEN 1 END)                          AS dead_no_damage_count,
        COUNT(CASE WHEN l.current_milestone = 'Dead'
                    AND l.dead_lead_reason != 'No Damage'
                   THEN 1 END)                          AS dead_controllable,

        SUM(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total ELSE 0 END)      AS total_revenue,
        SUM(CASE WHEN l.current_milestone
                 IN ('Approved','Invoiced','Completed')
                 THEN l.contract_total ELSE 0 END)      AS pipeline_value,
        AVG(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total END)             AS avg_contract_value,

        -- Insurance adjusted close rate
        CAST(ROUND(
            COUNT(CASE WHEN l.current_milestone = 'Closed'
                        AND ls.source_category = 'Insurance' THEN 1 END) * 100.0 /
            NULLIF(
                COUNT(CASE WHEN l.current_milestone = 'Closed'
                            AND ls.source_category = 'Insurance' THEN 1 END) +
                COUNT(CASE WHEN l.current_milestone = 'Dead'
                            AND ls.source_category = 'Insurance'
                            AND l.dead_lead_reason != 'No Damage' THEN 1 END)
            , 0)
        , 1) AS DECIMAL(10,1))                          AS insurance_close_rate,

        -- Referral adjusted close rate
        CAST(ROUND(
            COUNT(CASE WHEN l.current_milestone = 'Closed'
                        AND ls.source_category = 'Referral' THEN 1 END) * 100.0 /
            NULLIF(
                COUNT(CASE WHEN l.current_milestone = 'Closed'
                            AND ls.source_category = 'Referral' THEN 1 END) +
                COUNT(CASE WHEN l.current_milestone = 'Dead'
                            AND ls.source_category = 'Referral'
                            AND l.dead_lead_reason != 'No Damage' THEN 1 END)
            , 0)
        , 1) AS DECIMAL(10,1))                          AS referral_close_rate

    FROM sales_reps sr
    LEFT JOIN leads l       ON sr.rep_id   = l.rep_id
    LEFT JOIN lead_sources ls ON l.source_id = ls.source_id
    GROUP BY sr.rep_id, sr.full_name
),

close_rates AS (
    SELECT
        rep_name,
        total_leads,
        closed_count,
        dead_count,
        dead_no_damage_count,
        dead_controllable,
        CASE
            WHEN total_leads < 10 THEN 'Too Small'
            WHEN total_leads < 25 THEN 'Small Sample'
            ELSE                       'Reliable'
        END                                             AS sample_flag,
        CAST(ROUND(
            closed_count * 100.0 /
            NULLIF(closed_count + dead_count, 0)
        , 1) AS DECIMAL(10,1))                          AS raw_close_rate,
        CAST(ROUND(
            dead_no_damage_count * 100.0 /
            NULLIF(total_leads, 0)
        , 1) AS DECIMAL(10,1))                          AS no_damage_rate_pct,
        CAST(ROUND(
            closed_count * 100.0 /
            NULLIF(closed_count + dead_controllable, 0)
        , 1) AS DECIMAL(10,1))                          AS adjusted_close_rate,
        total_revenue,
        pipeline_value,
        avg_contract_value,
        insurance_close_rate,
        referral_close_rate
    FROM rep_calculations
)

SELECT
    rep_name,
    total_leads,
    closed_count,
    dead_count,
    dead_no_damage_count,
    dead_controllable,
    sample_flag,
    raw_close_rate,
    no_damage_rate_pct,
    adjusted_close_rate,
    total_revenue,
    pipeline_value,
    avg_contract_value,
    DENSE_RANK() OVER(ORDER BY total_leads DESC)            AS rep_leads_rank,
    DENSE_RANK() OVER(ORDER BY adjusted_close_rate DESC)    AS rep_adj_close_rate_rank,
    DENSE_RANK() OVER(ORDER BY total_revenue DESC)          AS rep_total_revenue_rank,
    DENSE_RANK() OVER(ORDER BY avg_contract_value DESC)     AS rep_avg_contract_rank,
    insurance_close_rate,
    referral_close_rate
FROM close_rates
ORDER BY total_revenue DESC;
GO


-- ------------------------------------------------------------
-- 2b. Dead lead reason breakdown by rep
--     Wide format — one row per rep, one column per reason.
--     Shows which failure modes are most common per rep.
--     JOIN condition on milestone filters to Dead only
--     while keeping all reps (avoids WHERE canceling LEFT JOIN).
-- ------------------------------------------------------------
SELECT
    sr.rep_id,
    sr.full_name                                        AS sales_rep,
    COUNT(CASE WHEN l.dead_lead_reason = 'Bad Lead from Lead Service'
               THEN 1 END)                              AS bad_lead_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'Estimated Cost was Too High'
               THEN 1 END)                              AS cost_too_high_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'No Answer/No Response (Ghosted)'
               THEN 1 END)                              AS ghosted_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'No Damage'
               THEN 1 END)                              AS no_damage_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'Not Ready Yet'
               THEN 1 END)                              AS not_ready_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'Not services that we provide.'
               THEN 1 END)                              AS not_our_service_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'Other'
               THEN 1 END)                              AS other_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'We turned down the job'
               THEN 1 END)                              AS we_turned_down_count,
    COUNT(CASE WHEN l.dead_lead_reason = 'Went with Someone Else'
               THEN 1 END)                              AS went_elsewhere_count,
    SUM(COUNT(*)) OVER (PARTITION BY sr.full_name)      AS total_dead
FROM sales_reps sr
LEFT JOIN leads l
    ON sr.rep_id = l.rep_id
    AND l.current_milestone = 'Dead'
GROUP BY sr.rep_id, sr.full_name;
GO


-- ------------------------------------------------------------
-- 2c. Rep performance by insurance company
--     Answers: "Given this customer has State Farm insurance,
--     which of my reps should I assign this lead to?"
--     HAVING clause filters to meaningful sample sizes only.
-- ------------------------------------------------------------
SELECT
    sr.full_name            AS rep_name,
    ic.company_name         AS insurance_company,
    COUNT(l.lead_id)        AS total_leads,
    COUNT(CASE WHEN l.current_milestone = 'Closed'
               THEN 1 END)  AS closed,
    COUNT(CASE WHEN l.current_milestone = 'Dead'
                AND l.dead_lead_reason != 'No Damage'
               THEN 1 END)  AS dead_controllable,
    ROUND(
        COUNT(CASE WHEN l.current_milestone = 'Closed' THEN 1 END) * 100.0 /
        NULLIF(
            COUNT(CASE WHEN l.current_milestone = 'Closed' THEN 1 END) +
            COUNT(CASE WHEN l.current_milestone = 'Dead'
                        AND l.dead_lead_reason != 'No Damage' THEN 1 END)
        , 0)
    , 1)                    AS adjusted_close_rate,
    AVG(CASE WHEN l.current_milestone = 'Closed'
             THEN pt.lead_to_closed_days END)           AS avg_days_to_close,
    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)          AS closed_revenue
FROM leads l
INNER JOIN sales_reps sr          ON l.rep_id     = sr.rep_id
INNER JOIN insurance_companies ic ON l.company_id = ic.company_id
LEFT JOIN  pipeline_timing pt     ON l.lead_id    = pt.lead_id
GROUP BY sr.full_name, ic.company_name
HAVING COUNT(l.lead_id) >= 3
ORDER BY ic.company_name, closed_revenue DESC;
GO


-- ============================================================
-- SECTION 3: INSURANCE COMPANY RANKINGS
-- ============================================================

-- ------------------------------------------------------------
-- 3a. Insurance company ranking
--     Ranks by revenue, lead volume, and approval rate.
--     DENSE_RANK used so ties don't create gaps in ranking.
--     Composite ranking averages the three individual ranks.
--     pct_of_total_revenue uses empty OVER() window —
--     no partition means grand total across all companies.
-- ------------------------------------------------------------
WITH insurance_calculations AS (
    SELECT
        ic.company_name                                 AS insurance,
        COUNT(l.lead_id)                                AS total_leads,
        SUM(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total ELSE 0 END)      AS closed_revenue,
        SUM(CASE WHEN l.current_milestone
                 IN ('Approved','Invoiced','Completed')
                 THEN l.contract_total ELSE 0 END)      AS pipeline_value,
        COUNT(CASE WHEN l.current_milestone
                   IN ('Approved','Invoiced','Completed','Closed')
                   THEN 1 END)                          AS approved_count,
        CAST(ROUND(
            COUNT(CASE WHEN l.current_milestone
                       IN ('Approved','Invoiced','Completed','Closed')
                       THEN 1 END) * 100.0 /
            NULLIF(COUNT(l.lead_id), 0)
        , 1) AS DECIMAL(10,1))                          AS approval_rate_pct,
        COUNT(CASE WHEN l.current_milestone = 'Dead'
                    AND l.dead_lead_reason != 'No Damage'
                   THEN 1 END)                          AS dead_controllable
    FROM insurance_companies ic
    LEFT JOIN leads l ON ic.company_id = l.company_id
    GROUP BY ic.company_name
),

rankings AS (
    SELECT
        insurance,
        total_leads,
        closed_revenue,
        pipeline_value,
        approval_rate_pct,
        CAST(ROUND(
            closed_revenue * 100.0 /
            NULLIF(SUM(closed_revenue) OVER(), 0)
        , 1) AS DECIMAL(10,1))                          AS pct_of_total_revenue,
        DENSE_RANK() OVER(ORDER BY total_leads DESC)    AS volume_rank,
        DENSE_RANK() OVER(ORDER BY closed_revenue DESC) AS revenue_rank,
        DENSE_RANK() OVER(ORDER BY approval_rate_pct DESC) AS approval_rank
    FROM insurance_calculations
)

SELECT
    insurance,
    total_leads,
    volume_rank,
    closed_revenue,
    revenue_rank,
    pipeline_value,
    approval_rate_pct,
    approval_rank,
    pct_of_total_revenue
FROM rankings
ORDER BY revenue_rank;
GO


-- ------------------------------------------------------------
-- 3b. Insurance company pipeline breakdown
--     Shows closed revenue, pipeline value, and job counts
--     at each active stage per insurer.
--     Useful for identifying which companies have approved
--     work waiting to be completed.
-- ------------------------------------------------------------
SELECT
    ic.company_name,
    COUNT(l.lead_id)                                    AS total_leads,
    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)          AS closed_revenue,
    SUM(CASE WHEN l.current_milestone
             IN ('Approved','Invoiced','Completed')
             THEN l.contract_total ELSE 0 END)          AS pipeline_value,
    SUM(CASE WHEN l.current_milestone
             IN ('Approved','Invoiced','Completed','Closed')
             THEN l.contract_total ELSE 0 END)          AS total_committed_value,
    COUNT(CASE WHEN l.current_milestone = 'Approved'
               THEN 1 END)                              AS approved_jobs,
    COUNT(CASE WHEN l.current_milestone = 'Invoiced'
               THEN 1 END)                              AS invoiced_jobs,
    COUNT(CASE WHEN l.current_milestone = 'Completed'
               THEN 1 END)                              AS completed_jobs
FROM insurance_companies ic
LEFT JOIN leads l ON ic.company_id = l.company_id
GROUP BY ic.company_name
ORDER BY total_committed_value DESC;
GO


-- ------------------------------------------------------------
-- 3c. Average days to close by insurance company
--     Cycle time analysis on closed deals only.
--     JOIN condition filters to Closed milestone to avoid
--     averaging partial journeys from in-progress leads.
-- ------------------------------------------------------------
SELECT
    ic.company_id,
    ic.company_name,
    AVG(CASE WHEN pt.lead_to_approved_days > 0
             THEN pt.lead_to_approved_days END)         AS avg_lead_to_approved_days,
    AVG(CASE WHEN pt.approved_to_closed_days > 0
             THEN pt.approved_to_closed_days END)       AS avg_approved_to_closed_days,
    AVG(CASE WHEN pt.lead_to_closed_days > 0
             THEN pt.lead_to_closed_days END)           AS avg_lead_to_closed_days
FROM insurance_companies ic
LEFT JOIN leads l
    ON ic.company_id = l.company_id
    AND l.current_milestone = 'Closed'
LEFT JOIN pipeline_timing pt ON l.lead_id = pt.lead_id
GROUP BY ic.company_id, ic.company_name
ORDER BY avg_lead_to_closed_days;
GO


-- ============================================================
-- SECTION 4: INSURANCE AGENT RANKINGS
-- ============================================================

-- ------------------------------------------------------------
-- 4a. Agent ranking with relationship priority scoring
--     Answers: "Which agents should I invest time in?"
--     Priority logic uses total_value (closed + pipeline)
--     rather than closed revenue alone — accounts for CRM
--     closure delays that understate active agent performance.
--     Weighted approval rate discounts small samples:
--       weighted = raw_rate * (leads / (leads + 10))
--     An agent with 2 leads at 100% gets weighted down.
--     An agent with 20 leads at 60% is ranked more reliably.
-- ------------------------------------------------------------
WITH agent_calculations AS (
    SELECT
        ic.company_name                                 AS insurance,
        ia.agent_name,
        COUNT(l.lead_id)                                AS leads,
        SUM(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total ELSE 0 END)      AS revenue,
        CAST(ROUND(
            AVG(CASE WHEN l.current_milestone = 'Closed'
                     THEN l.contract_total END)
        , 2) AS DECIMAL(10,2))                          AS avg_contract_value,
        CAST(ROUND(
            COUNT(CASE WHEN l.current_milestone
                       IN ('Approved','Invoiced','Completed','Closed')
                       THEN 1 END) * 100.0 /
            NULLIF(COUNT(l.lead_id), 0)
        , 1) AS DECIMAL(10,1))                          AS approval_rate_pct
    FROM insurance_companies ic
    JOIN insurance_agents ia ON ic.company_id = ia.company_id
    LEFT JOIN leads l        ON ia.agent_id   = l.agent_id
    GROUP BY ic.company_name, ia.agent_name
),

weighted_rankings AS (
    SELECT
        insurance,
        agent_name,
        leads,
        revenue,
        approval_rate_pct,
        (leads * 1.0 / (leads + 10.0))                 AS confidence_weight,
        CAST(ROUND(
            approval_rate_pct * (leads * 1.0 / (leads + 10.0))
        , 1) AS DECIMAL(10,1))                          AS weighted_approval,
        CASE
            WHEN leads < 5  THEN 'Too Small'
            WHEN leads < 10 THEN 'Small Sample'
            ELSE                 'Reliable'
        END                                             AS sample_flag
    FROM agent_calculations
),

rankings AS (
    SELECT
        insurance,
        agent_name,
        leads,
        revenue,
        approval_rate_pct,
        confidence_weight,
        sample_flag,
        weighted_approval,
        DENSE_RANK() OVER(ORDER BY leads DESC)                          AS leads_rank,
        DENSE_RANK() OVER(ORDER BY revenue DESC)                        AS revenue_rank,
        DENSE_RANK() OVER(ORDER BY approval_rate_pct DESC)              AS approval_rate_rank,
        DENSE_RANK() OVER(PARTITION BY insurance ORDER BY leads DESC)   AS leads_rank_by_company,
        DENSE_RANK() OVER(PARTITION BY insurance
                          ORDER BY weighted_approval DESC)              AS approval_rank_weighted
    FROM weighted_rankings
)

SELECT
    insurance,
    agent_name,
    leads,
    revenue,
    approval_rate_pct,
    leads_rank,
    revenue_rank,
    leads_rank_by_company,
    sample_flag,
    weighted_approval,
    approval_rank_weighted
FROM rankings
ORDER BY revenue_rank;
GO


-- ============================================================
-- SECTION 5: LEAD SOURCE ANALYSIS
-- ============================================================

-- ------------------------------------------------------------
-- 5a. Lead source performance by category
--     Approval rate denominator = total_leads (not closed).
--     Adjusted close rate excludes No Damage from denominator.
--     DENSE_RANK without PARTITION BY = global ranking
--     across all 4 categories.
-- ------------------------------------------------------------
WITH lead_source_calculations AS (
    SELECT
        ls.source_category,
        COUNT(l.lead_id)                                AS total_leads,
        COUNT(CASE WHEN l.dead_lead_reason = 'No Damage'
                   THEN 1 END)                          AS no_damage_count,
        COUNT(CASE WHEN l.current_milestone
                   IN ('Approved','Invoiced','Completed','Closed')
                   THEN 1 END)                          AS approved_count,
        COUNT(CASE WHEN l.current_milestone = 'Closed'
                   THEN 1 END)                          AS closed_count,
        SUM(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total ELSE 0 END)      AS closed_revenue,
        AVG(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total END)             AS avg_contract_value,
        SUM(CASE WHEN l.current_milestone
                 IN ('Approved','Invoiced','Completed')
                 THEN l.contract_total ELSE 0 END)      AS pipeline_value,
        COUNT(CASE WHEN l.current_milestone = 'Dead'
                    AND l.dead_lead_reason != 'No Damage'
                   THEN 1 END)                          AS dead_controllable
    FROM lead_sources ls
    LEFT JOIN leads l ON ls.source_id = l.source_id
    GROUP BY ls.source_category
),

lead_rates AS (
    SELECT
        source_category,
        total_leads,
        no_damage_count,
        approved_count,
        closed_count,
        closed_revenue,
        avg_contract_value,
        pipeline_value,
        dead_controllable,
        CAST(ROUND(
            approved_count * 100.0 / NULLIF(total_leads, 0)
        , 1) AS DECIMAL(10,1))                          AS approval_rate,
        CAST(ROUND(
            closed_count * 100.0 /
            NULLIF(closed_count + dead_controllable, 0)
        , 1) AS DECIMAL(10,1))                          AS adjusted_close_rate
    FROM lead_source_calculations
)

SELECT
    source_category,
    total_leads,
    no_damage_count,
    approved_count,
    closed_count,
    closed_revenue,
    avg_contract_value,
    pipeline_value,
    approval_rate,
    adjusted_close_rate,
    DENSE_RANK() OVER(ORDER BY closed_revenue DESC)     AS revenue_rank,
    DENSE_RANK() OVER(ORDER BY avg_contract_value DESC) AS avg_contract_rank,
    DENSE_RANK() OVER(ORDER BY approval_rate DESC)      AS approval_rank,
    DENSE_RANK() OVER(ORDER BY adjusted_close_rate DESC) AS close_rate_rank
FROM lead_rates
ORDER BY closed_revenue DESC;
GO


-- ------------------------------------------------------------
-- 5b. Lead source performance by individual source
--     Same as 5a but grouped by individual source name.
--     PARTITION BY source_category ranks each source
--     within its category — e.g. Google Organic ranked
--     against Website and Internet (not against Referral).
-- ------------------------------------------------------------
WITH lead_source_calculations AS (
    SELECT
        ls.source_id,
        ls.source_name,
        ls.source_category,
        COUNT(l.lead_id)                                AS total_leads,
        COUNT(CASE WHEN l.dead_lead_reason = 'No Damage'
                   THEN 1 END)                          AS no_damage_count,
        COUNT(CASE WHEN l.current_milestone
                   IN ('Approved','Invoiced','Completed','Closed')
                   THEN 1 END)                          AS approved_count,
        COUNT(CASE WHEN l.current_milestone = 'Closed'
                   THEN 1 END)                          AS closed_count,
        SUM(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total ELSE 0 END)      AS closed_revenue,
        AVG(CASE WHEN l.current_milestone = 'Closed'
                 THEN l.contract_total END)             AS avg_contract_value,
        SUM(CASE WHEN l.current_milestone
                 IN ('Approved','Invoiced','Completed')
                 THEN l.contract_total ELSE 0 END)      AS pipeline_value,
        COUNT(CASE WHEN l.current_milestone = 'Dead'
                    AND l.dead_lead_reason != 'No Damage'
                   THEN 1 END)                          AS dead_controllable
    FROM lead_sources ls
    LEFT JOIN leads l ON ls.source_id = l.source_id
    GROUP BY ls.source_id, ls.source_name, ls.source_category
),

lead_rates AS (
    SELECT
        source_name,
        source_category,
        total_leads,
        no_damage_count,
        approved_count,
        closed_count,
        closed_revenue,
        avg_contract_value,
        pipeline_value,
        dead_controllable,
        CAST(ROUND(
            approved_count * 100.0 / NULLIF(total_leads, 0)
        , 1) AS DECIMAL(10,1))                          AS approval_rate,
        CAST(ROUND(
            closed_count * 100.0 /
            NULLIF(closed_count + dead_controllable, 0)
        , 1) AS DECIMAL(10,1))                          AS adjusted_close_rate
    FROM lead_source_calculations
)

SELECT
    source_name,
    source_category,
    total_leads,
    no_damage_count,
    approved_count,
    closed_count,
    closed_revenue,
    avg_contract_value,
    pipeline_value,
    approval_rate,
    adjusted_close_rate,
    DENSE_RANK() OVER(PARTITION BY source_category
                      ORDER BY closed_revenue DESC)     AS revenue_rank,
    DENSE_RANK() OVER(PARTITION BY source_category
                      ORDER BY avg_contract_value DESC) AS avg_contract_rank,
    DENSE_RANK() OVER(PARTITION BY source_category
                      ORDER BY approval_rate DESC)      AS approval_rank,
    DENSE_RANK() OVER(PARTITION BY source_category
                      ORDER BY adjusted_close_rate DESC) AS close_rate_rank
FROM lead_rates
ORDER BY closed_revenue DESC;
GO


-- ============================================================
-- SECTION 6: REFERRAL ORIGIN ANALYSIS
-- ============================================================

-- ------------------------------------------------------------
-- 6a. Referral origin classification
--     Attempts to trace leads back to insurance origin.
--     Three categories:
--       Direct Insurance     — Lead Source = Insurance Agents
--       Insurance Referral   — Referral with agent_id populated
--                              (agent name was in Damage Location)
--       Non Insurance Origin — All other sources
--
--     LIMITATION: CRM does not capture referrer name.
--     If Customer A (insurance) refers Customer B, B is
--     recorded as Referral with no link back to A.
--     Only 4 referral rows have an agent_id (9 originally
--     before agent cleanup) — these are rows where someone
--     manually entered an agent name in Damage Location
--     on a referral lead.
--     Full referral chain analysis requires adding a
--     "Referred By" field to the CRM going forward.
-- ------------------------------------------------------------
WITH origin_tags AS (
    SELECT
        l.lead_id,
        l.customer_name,
        l.current_milestone,
        l.contract_total,
        ls.source_name,
        CASE
            WHEN ls.source_name = 'Insurance Agents'
                THEN 'Direct Insurance'
            WHEN ls.source_name = 'Referral'
             AND ia.agent_id IS NOT NULL
                THEN 'Insurance Origin Referral'
            ELSE 'Non Insurance Origin'
        END                                             AS origin_tag
    FROM leads l
    INNER JOIN lead_sources ls    ON l.source_id = ls.source_id
    LEFT JOIN  insurance_agents ia ON l.agent_id  = ia.agent_id
),

origin_summary AS (
    SELECT
        origin_tag,
        COUNT(lead_id)                                  AS total_leads,
        COUNT(CASE WHEN current_milestone = 'Closed'
                   THEN 1 END)                          AS closed_count,
        SUM(CASE WHEN current_milestone = 'Closed'
                 THEN contract_total ELSE 0 END)        AS closed_revenue,
        SUM(CASE WHEN current_milestone
                 IN ('Approved','Invoiced','Completed')
                 THEN contract_total ELSE 0 END)        AS pipeline_value,
        CAST(ROUND(
            COUNT(CASE WHEN current_milestone = 'Closed'
                       THEN 1 END) * 100.0 /
            NULLIF(COUNT(lead_id), 0)
        , 1) AS DECIMAL(10,1))                          AS close_rate_pct
    FROM origin_tags
    GROUP BY origin_tag
)

SELECT
    origin_tag,
    total_leads,
    closed_count,
    closed_revenue,
    pipeline_value,
    close_rate_pct,
    CAST(ROUND(
        closed_revenue * 100.0 /
        NULLIF(SUM(closed_revenue) OVER (), 0)
    , 1) AS DECIMAL(10,1))                              AS pct_of_total_revenue
FROM origin_summary
ORDER BY closed_revenue DESC;
GO


-- ============================================================
-- SECTION 7: AD HOC DIAGNOSTIC QUERIES
-- ============================================================

-- ------------------------------------------------------------
-- 7a. Agent detail drill-down
--     Run for any agent showing unexpected results.
--     Shows milestone breakdown and pipeline value.
-- ------------------------------------------------------------
SELECT
    l.current_milestone,
    r.full_name                 AS sales_rep,
    l.customer_name,
    pt.approved_days,
    pt.total_process_days,
    l.contract_total
FROM leads l
INNER JOIN insurance_agents ia  ON l.agent_id  = ia.agent_id
INNER JOIN sales_reps r         ON l.rep_id    = r.rep_id
INNER JOIN pipeline_timing pt   ON l.lead_id   = pt.lead_id
WHERE ia.agent_name = 'Agent 174'   -- Replace with target agent name
ORDER BY l.current_milestone, pt.approved_days DESC;
GO


-- ------------------------------------------------------------
-- 7b. Rep pipeline diagnostic
--     Run for any rep showing unusual numbers.
--     Breaks down milestone distribution and pipeline value.
-- ------------------------------------------------------------
SELECT
    l.current_milestone,
    COUNT(*)                    AS count,
    l.dead_lead_reason,
    SUM(l.contract_total)       AS total_value
FROM leads l
INNER JOIN sales_reps sr ON l.rep_id = sr.rep_id
WHERE sr.full_name = 'Rep G'    -- Replace with target rep name
GROUP BY l.current_milestone, l.dead_lead_reason
ORDER BY count DESC;
GO


-- ------------------------------------------------------------
-- 7c. Insurance agent match rate verification
--     Checks how many insurance agent leads successfully
--     resolved to a known agent after ETL cleanup.
--     Target: 74+ unmatched (those with no agent recorded)
--     Any additional unmatched rows indicate ETL gaps.
-- ------------------------------------------------------------
SELECT
    COUNT(*)                                            AS total_insurance_leads,
    SUM(CASE WHEN l.agent_id IS NULL THEN 1 ELSE 0 END) AS missing_agent,
    SUM(CASE WHEN l.agent_id IS NOT NULL THEN 1 ELSE 0 END) AS matched_agent
FROM leads l
INNER JOIN lead_sources ls ON l.source_id = ls.source_id
WHERE ls.source_name = 'Insurance Agents';
GO


-- ------------------------------------------------------------
-- 7d. Door knocking full breakdown
--     Sample size too small for close rate analysis.
--     Use pipeline value to assess true potential.
-- ------------------------------------------------------------
SELECT
    l.current_milestone,
    COUNT(*)                    AS count,
    l.dead_lead_reason,
    SUM(l.contract_total)       AS total_value
FROM leads l
INNER JOIN lead_sources ls ON l.source_id = ls.source_id
WHERE ls.source_name = 'Door Knocking'
GROUP BY l.current_milestone, l.dead_lead_reason
ORDER BY count DESC;
GO


-- ============================================================
-- END OF ANALYSIS QUERIES
-- ============================================================
