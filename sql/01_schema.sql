-- ============================================================
-- SUMMIT ROOFING — ANALYTICS DATABASE SCHEMA
-- Microsoft SQL Server (T-SQL)
-- ============================================================
-- Author:   Portfolio Project
-- Version:  1.0
--
-- EXECUTION ORDER:
--   1. Create database manually in SSMS or run:
--      CREATE DATABASE roofing_crm;
--   2. Set context: USE roofing_crm;
--   3. Run this file in full
--
-- REQUIREMENTS:
--   SQL Server 2016+ (required for CREATE OR ALTER VIEW)
--
-- TABLES (7):
--   Dimension: sales_reps, insurance_companies,
--              insurance_agents, lead_sources, sub_lead_sources
--   Fact:      leads, pipeline_timing, payments
--
-- VIEWS (6):
--   vw_referral_chain
--   vw_insurance_origin_leads
--   vw_rep_close_rates
--   vw_insurance_company_ranking
--   vw_insurance_agent_ranking
--   vw_agent_relationship_priority
-- ============================================================


-- ============================================================
-- DIMENSION TABLES
-- ============================================================

-- ------------------------------------------------------------
-- 1. SALES_REPS
--    One row per sales representative.
--    Single source of truth for rep names —
--    prevents whitespace/typo duplicates from CRM exports.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'sales_reps')
CREATE TABLE sales_reps (
    rep_id      INT             IDENTITY(1,1)   PRIMARY KEY,
    full_name   NVARCHAR(100)   NOT NULL,
    email       NVARCHAR(150)   NULL,
    hire_date   DATE            NULL,
    is_active   BIT             NOT NULL        DEFAULT 1,
    created_at  DATETIME        NOT NULL        DEFAULT GETDATE(),

    CONSTRAINT uq_rep_name UNIQUE (full_name)
);
GO


-- ------------------------------------------------------------
-- 2. INSURANCE_COMPANIES
--    Normalized insurer names.
--    normalized_name (lowercase) used for deduplication
--    during ETL to handle variants like
--    "Farmers" vs "Farmers Ins".
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'insurance_companies')
CREATE TABLE insurance_companies (
    company_id      INT             IDENTITY(1,1)   PRIMARY KEY,
    company_name    NVARCHAR(100)   NOT NULL,
    normalized_name NVARCHAR(100)   NOT NULL,
    is_active       BIT             NOT NULL        DEFAULT 1,

    CONSTRAINT uq_normalized_name UNIQUE (normalized_name)
);
GO


-- ------------------------------------------------------------
-- 3. INSURANCE_AGENTS
--    One row per agent. Links to their company.
--    agent_name sourced from the CRM "Damage Location"
--    field which stores agent name/office — not a physical
--    damage address (mislabeled field in source CRM).
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'insurance_agents')
CREATE TABLE insurance_agents (
    agent_id        INT             IDENTITY(1,1)   PRIMARY KEY,
    company_id      INT             NOT NULL        REFERENCES insurance_companies(company_id),
    agent_name      NVARCHAR(150)   NOT NULL,
    office_location NVARCHAR(200)   NULL,
    is_active       BIT             NOT NULL        DEFAULT 1,
    created_at      DATETIME        NOT NULL        DEFAULT GETDATE(),

    CONSTRAINT uq_agent_per_company UNIQUE (company_id, agent_name)
);
GO


-- ------------------------------------------------------------
-- 4. LEAD_SOURCES
--    Normalized lead source categories.
--    is_insurance_origin flags sources that feed the
--    referral chain analysis.
--    is_catchall flags generic catch-all entries
--    ("Other", "ZZ Rarely used") from the CRM.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'lead_sources')
CREATE TABLE lead_sources (
    source_id           INT             IDENTITY(1,1)   PRIMARY KEY,
    source_name         NVARCHAR(100)   NOT NULL,
    source_category     NVARCHAR(50)    NULL,
    is_insurance_origin BIT             NOT NULL        DEFAULT 0,
    is_catchall         BIT             NOT NULL        DEFAULT 0,

    CONSTRAINT uq_source_name UNIQUE (source_name)
);
GO


-- ------------------------------------------------------------
-- 5. SUB_LEAD_SOURCES
--    Granular breakdown within lead sources.
--    Example: Internet → Google Organic, Website, Angi's List
--    Links to lead_sources via source_id.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'sub_lead_sources')
CREATE TABLE sub_lead_sources (
    sub_source_id   INT             IDENTITY(1,1)   PRIMARY KEY,
    sub_source_name NVARCHAR(100)   NOT NULL,
    source_id       INT             NOT NULL        REFERENCES lead_sources(source_id),

    CONSTRAINT uq_sub_source UNIQUE (source_id, sub_source_name)
);
GO


-- ============================================================
-- FACT TABLES
-- ============================================================

-- ------------------------------------------------------------
-- 6. LEADS
--    Core fact table. One row per lead/job.
--
--    KEY DESIGN DECISIONS:
--
--    a) referred_by_lead_id — self-referencing FK.
--       Points to the lead_id of the customer who made
--       the referral. NULL when not a referral.
--
--    b) origin_lead_id — root of the referral chain.
--       If A (insurance lead) refers B, and B refers C:
--         A.origin_lead_id = NULL  (A is the origin)
--         B.origin_lead_id = A.lead_id
--         C.origin_lead_id = A.lead_id  (not B)
--       Enables owner's definition: "if insurance refers A
--       and A refers B, B is still an insurance-origin lead."
--
--    c) origin_source_id — denormalized for query performance.
--       Backfilled using vw_referral_chain after ETL load.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'leads')
CREATE TABLE leads (
    lead_id             INT             IDENTITY(1,1)   PRIMARY KEY,
    job_number          NVARCHAR(20)    NULL,
    customer_name       NVARCHAR(200)   NOT NULL,

    -- Relationships
    rep_id              INT             NULL    REFERENCES sales_reps(rep_id),
    source_id           INT             NOT NULL REFERENCES lead_sources(source_id),
    sub_source_id       INT             NULL    REFERENCES sub_lead_sources(sub_source_id),
    agent_id            INT             NULL    REFERENCES insurance_agents(agent_id),
    company_id          INT             NULL    REFERENCES insurance_companies(company_id),

    -- Referral chain fields
    referred_by_lead_id INT             NULL    REFERENCES leads(lead_id),
    origin_lead_id      INT             NULL    REFERENCES leads(lead_id),
    origin_source_id    INT             NULL    REFERENCES lead_sources(source_id),

    -- Pipeline status
    current_milestone   NVARCHAR(50)    NOT NULL,
    contract_total      DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
    dead_lead_reason    NVARCHAR(100)   NULL,

    created_at          DATETIME        NOT NULL DEFAULT GETDATE(),
    updated_at          DATETIME        NOT NULL DEFAULT GETDATE(),

    CONSTRAINT chk_milestone CHECK (
        current_milestone IN (
            'Unassigned Lead', 'Assigned Lead', 'Prospect',
            'Approved', 'Invoiced', 'Completed', 'Closed', 'Dead'
        )
    ),
    CONSTRAINT chk_contract_non_negative CHECK (contract_total >= 0)
);
GO


-- ------------------------------------------------------------
-- 7. PIPELINE_TIMING
--    One-to-one with leads. Stores all CRM timing columns
--    separately to keep the fact table clean.
--    Note: prospect_days excluded from negative check
--    constraint — rare CRM entry errors can produce small
--    negatives; handled with ABS() during ETL load.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'pipeline_timing')
CREATE TABLE pipeline_timing (
    timing_id                   INT     IDENTITY(1,1)   PRIMARY KEY,
    lead_id                     INT     NOT NULL UNIQUE REFERENCES leads(lead_id),

    lead_days                   INT     NOT NULL DEFAULT 0,
    prospect_days               INT     NOT NULL DEFAULT 0,
    lead_to_approved_days       INT     NOT NULL DEFAULT 0,
    approved_days               INT     NOT NULL DEFAULT 0,
    approved_to_invoiced_days   INT     NOT NULL DEFAULT 0,
    approved_to_closed_days     INT     NOT NULL DEFAULT 0,
    completed_days              INT     NOT NULL DEFAULT 0,
    invoiced_days               INT     NOT NULL DEFAULT 0,
    lead_to_closed_days         INT     NOT NULL DEFAULT 0,
    lead_to_dead_days           INT     NOT NULL DEFAULT 0,
    total_process_days          INT     NOT NULL DEFAULT 0
);
GO


-- ------------------------------------------------------------
-- 8. PAYMENTS
--    Financial tracking per lead. Sourced from sales report.
--    Note: balance_due allows negatives — overpayments occur
--    when supplemental insurance payments arrive after
--    contract is written. These are valid business records.
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'payments')
CREATE TABLE payments (
    payment_id          INT             IDENTITY(1,1)   PRIMARY KEY,
    lead_id             INT             NOT NULL UNIQUE REFERENCES leads(lead_id),

    approved_date       DATE            NULL,
    contract_amount     DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
    payments_received   DECIMAL(10,2)   NOT NULL DEFAULT 0.00,
    balance_due         DECIMAL(10,2)   NOT NULL DEFAULT 0.00,

    CONSTRAINT chk_contract_non_negative_pay CHECK (contract_amount >= 0)
);
GO


-- ============================================================
-- INDEXES
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_rep_id')
    CREATE INDEX idx_leads_rep_id        ON leads(rep_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_company_id')
    CREATE INDEX idx_leads_company_id    ON leads(company_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_agent_id')
    CREATE INDEX idx_leads_agent_id      ON leads(agent_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_source_id')
    CREATE INDEX idx_leads_source_id     ON leads(source_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_origin_source')
    CREATE INDEX idx_leads_origin_source ON leads(origin_source_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_referred_by')
    CREATE INDEX idx_leads_referred_by   ON leads(referred_by_lead_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_origin_lead')
    CREATE INDEX idx_leads_origin_lead   ON leads(origin_lead_id);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_milestone')
    CREATE INDEX idx_leads_milestone     ON leads(current_milestone);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_dead_reason')
    CREATE INDEX idx_leads_dead_reason   ON leads(dead_lead_reason);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_leads_job_number')
    CREATE INDEX idx_leads_job_number    ON leads(job_number);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'idx_payments_approved')
    CREATE INDEX idx_payments_approved   ON payments(approved_date);
GO


-- ============================================================
-- VIEWS
-- ============================================================

-- ------------------------------------------------------------
-- V1. REFERRAL CHAIN RESOLVER
--    Recursive CTE that walks the referral chain to find
--    each lead's root origin source.
--    Note: semicolon before CREATE required in SQL Server
--    when view body begins with a CTE (WITH keyword).
-- ------------------------------------------------------------
;CREATE OR ALTER VIEW vw_referral_chain AS
WITH chain AS (

    -- Base case: leads with no referrer are the origin
    SELECT
        lead_id,
        lead_id     AS origin_lead_id,
        source_id   AS origin_source_id,
        0           AS chain_depth
    FROM leads
    WHERE referred_by_lead_id IS NULL

    UNION ALL

    -- Recursive case: walk up one level at a time
    SELECT
        l.lead_id,
        c.origin_lead_id,
        c.origin_source_id,
        c.chain_depth + 1
    FROM leads l
    INNER JOIN chain c ON l.referred_by_lead_id = c.lead_id

)
SELECT
    chain.lead_id,
    chain.origin_lead_id,
    chain.origin_source_id,
    chain.chain_depth,
    ls.source_name          AS origin_source_name,
    ls.is_insurance_origin  AS is_insurance_origin
FROM chain
INNER JOIN lead_sources ls ON chain.origin_source_id = ls.source_id;
GO


-- ------------------------------------------------------------
-- V2. INSURANCE ORIGIN LEADS
--    All leads tracing back to an Insurance Agent source,
--    whether direct or through a referral chain.
--    Implements business rule: "if insurance refers A and
--    A refers B, B is still an insurance-origin lead."
-- ------------------------------------------------------------
CREATE OR ALTER VIEW vw_insurance_origin_leads AS
SELECT
    l.lead_id,
    l.job_number,
    l.customer_name,
    l.current_milestone,
    l.contract_total,
    l.dead_lead_reason,
    ls_direct.source_name       AS direct_source,
    ls_origin.source_name       AS origin_source,
    rc.chain_depth,
    CASE
        WHEN rc.chain_depth = 0 THEN 'Direct'
        ELSE 'Referred (' + CAST(rc.chain_depth AS NVARCHAR(10)) + ' hop'
             + CASE WHEN rc.chain_depth > 1 THEN 's' ELSE '' END + ')'
    END                         AS referral_type,
    ic.company_name             AS insurance_company,
    ia.agent_name               AS insurance_agent,
    r.full_name                 AS sales_rep
FROM leads l
INNER JOIN vw_referral_chain rc     ON l.lead_id = rc.lead_id
INNER JOIN lead_sources ls_origin   ON rc.origin_source_id = ls_origin.source_id
INNER JOIN lead_sources ls_direct   ON l.source_id = ls_direct.source_id
LEFT JOIN  insurance_companies ic   ON l.company_id = ic.company_id
LEFT JOIN  insurance_agents ia      ON l.agent_id = ia.agent_id
LEFT JOIN  sales_reps r             ON l.rep_id = r.rep_id
WHERE ls_origin.is_insurance_origin = 1;
GO


-- ------------------------------------------------------------
-- V3. REP CLOSE RATES (ADJUSTED)
--    Two close rates per rep:
--      close_rate_raw_pct      = closed / (closed + all dead)
--      close_rate_adjusted_pct = closed / (closed + dead
--                                excluding No Damage)
--
--    "No Damage" dead leads excluded from adjusted rate
--    because the rep had no control over that outcome —
--    insurance company determined there was no covered damage.
--
--    Note: dead_controllable uses OR IS NULL to correctly
--    handle NULL dead_lead_reason values which SQL Server
--    excludes from != comparisons.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW vw_rep_close_rates AS
SELECT
    r.rep_id,
    r.full_name                                     AS rep_name,

    COUNT(l.lead_id)                                AS total_leads,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN 1 ELSE 0 END)                     AS closed,

    SUM(CASE WHEN l.current_milestone = 'Dead'
             THEN 1 ELSE 0 END)                     AS dead_total,

    SUM(CASE WHEN l.current_milestone = 'Dead'
              AND l.dead_lead_reason  = 'No Damage'
             THEN 1 ELSE 0 END)                     AS dead_no_damage,

    SUM(CASE WHEN l.current_milestone = 'Dead'
              AND (l.dead_lead_reason != 'No Damage'
                   OR l.dead_lead_reason IS NULL)
             THEN 1 ELSE 0 END)                     AS dead_controllable,

    -- Raw close rate
    ROUND(
        CAST(SUM(CASE WHEN l.current_milestone = 'Closed'
                      THEN 1 ELSE 0 END) AS DECIMAL(10,2))
        / NULLIF(SUM(CASE WHEN l.current_milestone IN ('Closed','Dead')
                          THEN 1 ELSE 0 END), 0) * 100
    , 1)                                            AS close_rate_raw_pct,

    -- Adjusted close rate (No Damage excluded from denominator)
    ROUND(
        CAST(SUM(CASE WHEN l.current_milestone = 'Closed'
                      THEN 1 ELSE 0 END) AS DECIMAL(10,2))
        / NULLIF(
            SUM(CASE WHEN l.current_milestone = 'Closed' THEN 1 ELSE 0 END)
          + SUM(CASE WHEN l.current_milestone = 'Dead'
                      AND (l.dead_lead_reason != 'No Damage'
                           OR l.dead_lead_reason IS NULL)
                     THEN 1 ELSE 0 END)
        , 0) * 100
    , 1)                                            AS close_rate_adjusted_pct,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)      AS total_revenue,

    SUM(CASE WHEN l.current_milestone
             IN ('Approved','Invoiced','Completed')
             THEN l.contract_total ELSE 0 END)      AS pipeline_value,

    ROUND(AVG(CASE WHEN l.current_milestone = 'Closed'
                   THEN l.contract_total END), 2)   AS avg_contract_value

FROM sales_reps r
INNER JOIN leads l ON r.rep_id = l.rep_id
GROUP BY r.rep_id, r.full_name;
GO


-- ------------------------------------------------------------
-- V4. INSURANCE COMPANY PERFORMANCE RANKING
--    Ranks insurers by lead volume, approval rate,
--    adjusted close rate, revenue, and cycle time.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW vw_insurance_company_ranking AS
SELECT
    ic.company_id,
    ic.company_name,

    COUNT(l.lead_id)                                AS total_leads,

    -- Approval rate: reached Approved or beyond
    ROUND(
        CAST(SUM(CASE WHEN l.current_milestone IN ('Approved','Invoiced','Completed','Closed')
                      THEN 1 ELSE 0 END) AS DECIMAL(10,2))
        / NULLIF(COUNT(l.lead_id), 0) * 100
    , 1)                                            AS approval_rate_pct,

    -- Adjusted close rate (No Damage excluded)
    ROUND(
        CAST(SUM(CASE WHEN l.current_milestone = 'Closed'
                      THEN 1 ELSE 0 END) AS DECIMAL(10,2))
        / NULLIF(
            SUM(CASE WHEN l.current_milestone = 'Closed' THEN 1 ELSE 0 END)
          + SUM(CASE WHEN l.current_milestone = 'Dead'
                      AND l.dead_lead_reason != 'No Damage'
                     THEN 1 ELSE 0 END)
        , 0) * 100
    , 1)                                            AS close_rate_adjusted_pct,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)      AS total_closed_revenue,

    ROUND(AVG(CASE WHEN l.current_milestone = 'Closed'
                   THEN l.contract_total END), 2)   AS avg_contract_value,

    -- Cycle time (closed deals only)
    ROUND(AVG(CASE WHEN l.current_milestone = 'Closed'
                   THEN CAST(pt.lead_to_closed_days AS DECIMAL(10,1))
              END), 1)                              AS avg_days_to_close,

    ROUND(AVG(CASE WHEN l.current_milestone IN ('Approved','Closed','Invoiced')
                   THEN CAST(pt.lead_to_approved_days AS DECIMAL(10,1))
              END), 1)                              AS avg_days_to_approve

FROM insurance_companies ic
INNER JOIN leads l            ON ic.company_id = l.company_id
LEFT JOIN  pipeline_timing pt ON l.lead_id = pt.lead_id
GROUP BY ic.company_id, ic.company_name;
GO


-- ------------------------------------------------------------
-- V5. INSURANCE AGENT RANKING
--    Ranks agents by lead volume, close rate, and revenue.
--    volume_tier supports new rep pipeline assignment —
--    high volume agents provide immediate lead flow for
--    reps without established relationships.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW vw_insurance_agent_ranking AS
SELECT
    ia.agent_id,
    ia.agent_name,
    ic.company_name,

    COUNT(l.lead_id)                                AS total_leads,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN 1 ELSE 0 END)                     AS closed_jobs,

    ROUND(
        CAST(SUM(CASE WHEN l.current_milestone = 'Closed'
                      THEN 1 ELSE 0 END) AS DECIMAL(10,2))
        / NULLIF(COUNT(l.lead_id), 0) * 100
    , 1)                                            AS close_rate_pct,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)      AS total_revenue,

    ROUND(AVG(CASE WHEN l.current_milestone = 'Closed'
                   THEN CAST(pt.lead_to_closed_days AS DECIMAL(10,1))
              END), 1)                              AS avg_days_to_close,

    CASE
        WHEN COUNT(l.lead_id) < 3  THEN 'New / Very Low'
        WHEN COUNT(l.lead_id) < 8  THEN 'Low'
        WHEN COUNT(l.lead_id) < 15 THEN 'Moderate'
        ELSE 'High Volume'
    END                                             AS volume_tier

FROM insurance_agents ia
INNER JOIN insurance_companies ic ON ia.company_id = ic.company_id
LEFT JOIN  leads l                ON ia.agent_id = l.agent_id
LEFT JOIN  pipeline_timing pt     ON l.lead_id = pt.lead_id
GROUP BY ia.agent_id, ia.agent_name, ic.company_name;
GO


-- ------------------------------------------------------------
-- V6. AGENT RELATIONSHIP PRIORITY
--    Scores each agent relationship for prioritization.
--    Directly answers: "Which agents should I invest time in?"
--
--    Priority logic:
--      Nurture — High Priority:
--        High volume (8+ leads) OR high closed revenue ($25K+)
--        AND total value (closed + pipeline) > $20K
--      Develop — Investigate:
--        High volume but low total value
--        Signals volume without conversion — investigate
--      Monitor — Growing:
--        3-7 leads — relationship developing
--      New / Inactive:
--        0-2 leads — dormant or just started
--
--    total_value = closed_revenue + pipeline_value
--    Pipeline value included because CRM closure delays
--    cause closed_revenue to understate true relationship
--    value for active agents.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW vw_agent_relationship_priority AS
SELECT
    ia.agent_name,
    ic.company_name,

    COUNT(l.lead_id)                                AS total_leads,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN 1 ELSE 0 END)                     AS closed_jobs,

    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END)      AS closed_revenue,

    SUM(CASE WHEN l.current_milestone
             IN ('Approved','Invoiced','Completed')
             THEN l.contract_total ELSE 0 END)      AS pipeline_value,

    -- Total value: closed + pipeline (accounts for CRM closure delays)
    SUM(CASE WHEN l.current_milestone = 'Closed'
             THEN l.contract_total ELSE 0 END) +
    SUM(CASE WHEN l.current_milestone
             IN ('Approved','Invoiced','Completed')
             THEN l.contract_total ELSE 0 END)      AS total_value,

    -- Adjusted close rate (No Damage excluded)
    ROUND(
        COUNT(CASE WHEN l.current_milestone = 'Closed'
                   THEN 1 END) * 100.0 /
        NULLIF(
            COUNT(CASE WHEN l.current_milestone = 'Closed' THEN 1 END) +
            COUNT(CASE WHEN l.current_milestone = 'Dead'
                        AND l.dead_lead_reason != 'No Damage' THEN 1 END)
        , 0)
    , 1)                                            AS adjusted_close_rate,

    CASE
        WHEN (COUNT(l.lead_id) >= 8
              OR SUM(CASE WHEN l.current_milestone = 'Closed'
                          THEN l.contract_total ELSE 0 END) >= 25000)
             AND (SUM(CASE WHEN l.current_milestone = 'Closed'
                           THEN l.contract_total ELSE 0 END)
                + SUM(CASE WHEN l.current_milestone
                           IN ('Approved','Invoiced','Completed')
                           THEN l.contract_total ELSE 0 END)) > 20000
             THEN 'Nurture — High Priority'
        WHEN COUNT(l.lead_id) >= 8
             AND (SUM(CASE WHEN l.current_milestone = 'Closed'
                           THEN l.contract_total ELSE 0 END)
                + SUM(CASE WHEN l.current_milestone
                           IN ('Approved','Invoiced','Completed')
                           THEN l.contract_total ELSE 0 END)) <= 20000
             THEN 'Develop — Investigate'
        WHEN COUNT(l.lead_id) BETWEEN 3 AND 7
             THEN 'Monitor — Growing'
        ELSE 'New / Inactive'
    END                                             AS relationship_priority

FROM insurance_agents ia
INNER JOIN insurance_companies ic ON ia.company_id = ic.company_id
LEFT JOIN  leads l                ON ia.agent_id   = l.agent_id
GROUP BY ia.agent_name, ic.company_name;
GO


-- ============================================================
-- UTILITY: BACKFILL REFERRAL CHAIN ORIGIN FIELDS
--    Run once after ETL load to populate origin_lead_id
--    and origin_source_id on the leads table.
--    These fields enable fast insurance-origin filtering
--    without recursive CTEs on every query.
-- ============================================================

-- UPDATE l
-- SET
--     l.origin_lead_id   = rc.origin_lead_id,
--     l.origin_source_id = rc.origin_source_id
-- FROM leads l
-- INNER JOIN vw_referral_chain rc ON l.lead_id = rc.lead_id
-- WHERE rc.chain_depth > 0;
-- GO


-- ============================================================
-- END OF SCHEMA
-- ============================================================
