-- ============================================================
-- SUMMIT ROOFING — ETL LOAD SCRIPT
-- Microsoft SQL Server (T-SQL)
-- ============================================================
-- Author:   Portfolio Project
-- Version:  1.0
--
-- PURPOSE:
--   Loads data from CRM staging tables into the normalized
--   roofing_crm schema. Run after 01_schema.sql.
--
-- PREREQUISITES:
--   01_schema.sql executed successfully
--   Staging tables loaded via SSMS Import Flat File wizard:
--     sales_leads  — from Lead_Sources_Report.csv
--                    (CRM leads export, includes insurance info)
--     stg_sales    — from Sales_Report.csv
--                    (CRM sales export, includes financials)
--
-- EXECUTION ORDER:
--   Tables must load in dependency order (FK constraints):
--   1.  sales_reps
--   2.  insurance_companies
--   3.  insurance_agents       (references insurance_companies)
--   4.  lead_sources
--   5.  sub_lead_sources       (references lead_sources)
--   6.  leads                  (references all above)
--   7.  pipeline_timing        (references leads)
--   8.  payments               (references leads)
--
-- DATA QUALITY NOTES:
--   - Agent names in CRM "Damage Location" field use format
--     "Agent Name - Staff Name". Dash-stripping extracts
--     the true agent name on load.
--   - Negative timing values (CRM entry errors) handled
--     with ABS() on pipeline_timing load.
--   - Duplicate staging rows handled with ROW_NUMBER()
--     deduplication on payments load.
--   - 4 overpayment records exist in payments (negative
--     balance_due). These are valid — supplemental insurance
--     payments arrived after contract was written.
--
-- RESET (if reloading from scratch):
--   TRUNCATE TABLE payments;
--   TRUNCATE TABLE pipeline_timing;
--   DELETE FROM leads;        -- DELETE not TRUNCATE (self-ref FK)
--   Dimension tables can be left intact unless source data changed.
-- ============================================================

USE roofing_crm;
GO


-- ============================================================
-- STEP 1: SALES REPS
--   UNION combines both staging files to catch all reps.
--   LTRIM/RTRIM trims whitespace found in CRM exports
--   (e.g. trailing space on some rep names).
--   UNION (not UNION ALL) removes cross-file duplicates.
-- ============================================================
INSERT INTO sales_reps (full_name)
SELECT DISTINCT LTRIM(RTRIM(Primary_Salesperson))
FROM sales_leads
WHERE Primary_Salesperson IS NOT NULL

UNION

SELECT DISTINCT LTRIM(RTRIM(Primary_Salesperson))
FROM stg_sales
WHERE Primary_Salesperson IS NOT NULL;
GO

-- Verify
-- SELECT * FROM sales_reps ORDER BY rep_id;


-- ============================================================
-- STEP 2: INSURANCE COMPANIES
--   normalized_name stores lowercase version for ETL matching.
--   Handles CRM variants like "Farmers Ins" vs "Farmers".
-- ============================================================
INSERT INTO insurance_companies (company_name, normalized_name)
SELECT DISTINCT
    LTRIM(RTRIM(Insurance_Company))            AS company_name,
    LOWER(LTRIM(RTRIM(Insurance_Company)))     AS normalized_name
FROM sales_leads
WHERE Insurance_Company IS NOT NULL;
GO

-- Verify
-- SELECT * FROM insurance_companies ORDER BY company_id;


-- ============================================================
-- STEP 3: INSURANCE AGENTS
--   Agent names sourced from the CRM "Damage Location" field
--   which stores "Agent Name - Staff Name" or just "Agent Name".
--   Dash-stripping extracts the true agent name.
--   GROUP BY collapses variants like "Austin Rolf" and
--   "Austin Rolf - Haley" into a single agent row.
--   MAX(office_location) retains the most descriptive raw
--   value for reference.
-- ============================================================
INSERT INTO insurance_agents (company_id, agent_name, office_location)
SELECT
    company_id,
    agent_name,
    MAX(office_location)
FROM (
    SELECT DISTINCT
        ic.company_id,
        CASE
            WHEN CHARINDEX('-', LTRIM(RTRIM(sl.Damage_Location))) > 0
            THEN LTRIM(RTRIM(
                    LEFT(sl.Damage_Location,
                         CHARINDEX('-', sl.Damage_Location) - 1)
                 ))
            ELSE LTRIM(RTRIM(sl.Damage_Location))
        END                                     AS agent_name,
        LTRIM(RTRIM(sl.Damage_Location))        AS office_location
    FROM sales_leads sl
    INNER JOIN insurance_companies ic
        ON LOWER(LTRIM(RTRIM(sl.Insurance_Company))) = ic.normalized_name
    WHERE sl.Lead_Source = 'Insurance Agents'
      AND sl.Damage_Location IS NOT NULL
) cleaned
GROUP BY company_id, agent_name;
GO

-- Verify
-- SELECT ia.agent_id, ia.agent_name, ic.company_name
-- FROM insurance_agents ia
-- INNER JOIN insurance_companies ic ON ia.company_id = ic.company_id
-- ORDER BY ic.company_name, ia.agent_name;


-- ============================================================
-- STEP 3a: AGENT NAME CLEANUP
--   Standardizes agent names in both the insurance_agents
--   table and the sales_leads staging table.
--   Staging table fixes ensure correct agent_id lookup
--   when leads are loaded in Step 6.
--
--   Issues addressed:
--   - Typos: Bret/Brett, Kristin/Kristen, Tischer/Tisher
--   - Punctuation: "Jim Hallam." -> "Jim Hallam"
--   - Abbreviations: "Flacke" -> "John Flacke"
--   - Merged entries: "Mike with Bruce Holiman" -> "Bruce Holiman"
--   - Referral notes: "Referred by Andrew Bishop..." -> deleted
--   - Non-agent entries: "Roof, Guttering..." -> deleted
-- ============================================================

-- Fix insurance_agents table
-- (Delete dirty versions where clean version already exists)
DELETE FROM insurance_agents WHERE agent_name = 'Flacke'                                    AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Jeff Tischer'                              AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Jeffrey Tisher'                            AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Jennifer & Andrew Williamson'              AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Williamson & Associates'                   AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Josh Peck'                                 AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Kristen Scholl'                            AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Mulder & Associates'                       AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Kyle Zeller''s agency'                     AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Kyle Zeller''s Office'                     AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Kimberly Ault from Nathan Ward''s office.' AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'american family');
DELETE FROM insurance_agents WHERE agent_name = 'Bret Farrar'                               AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Jim Hallam.'                               AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Michael Oerhke'                            AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Stacey Schell Newland'                     AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Stacy  Newland'                            AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Steve Shipman'                             AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Mike with Bruce Holiman'                   AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Roy Copeland'                              AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Rob Copeland (Silvia)'                     AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
DELETE FROM insurance_agents WHERE agent_name = 'Dan Welch  on 40 highway NEW AGENT REFERRAL' AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'shelter');
DELETE FROM insurance_agents WHERE agent_name = 'Referred by Andrew Bishop'                 AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'shelter');
DELETE FROM insurance_agents WHERE agent_name = 'Roof, Guttering, Gutter Guards, Front Window trim' AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'farmers ins');

-- Apply remaining name corrections
UPDATE insurance_agents SET agent_name = 'Rob Copeland'   WHERE agent_name = 'Roy Copeland'    AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
UPDATE insurance_agents SET agent_name = 'Bruce Holiman'  WHERE agent_name = 'Mike with Bruce Holiman' AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'state farm');
UPDATE insurance_agents SET agent_name = 'Derek Savage'   WHERE agent_name = 'Derek Savage.'   AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'other');
UPDATE insurance_agents SET agent_name = 'Sam Digiovanni' WHERE agent_name = 'Sam Digiovani'   AND company_id = (SELECT company_id FROM insurance_companies WHERE normalized_name = 'shelter');
GO

-- Standardize staging table agent names to match cleaned agent table
-- (Ensures correct agent_id resolution when leads are loaded)
UPDATE sales_leads SET Damage_Location = 'Michael Oehrke'      WHERE Damage_Location = 'Michael Oerhke';
UPDATE sales_leads SET Damage_Location = 'Brett Farrar'         WHERE Damage_Location IN ('Bret Farrar', 'Bret Farrar ', 'Bret Farrar - Rachel');
UPDATE sales_leads SET Damage_Location = 'Steven Shipman'       WHERE Damage_Location IN ('Steve Shipman', 'Steve Shipman ');
UPDATE sales_leads SET Damage_Location = 'Kristin Scholl'       WHERE Damage_Location = 'Kristen Scholl';
UPDATE sales_leads SET Damage_Location = 'Joshua Peck'          WHERE Damage_Location = 'Josh Peck - Kris';
UPDATE sales_leads SET Damage_Location = 'Stacy Newland'        WHERE Damage_Location IN ('Stacy  Newland', 'Stacey Schell Newland');
UPDATE sales_leads SET Damage_Location = 'Jeffrey Tischer'      WHERE Damage_Location IN ('Jeff Tischer', 'Jeffrey Tisher - Sarah Scaggs');
UPDATE sales_leads SET Damage_Location = 'John Flacke'          WHERE Damage_Location = 'Flacke';
UPDATE sales_leads SET Damage_Location = 'Jim Hallam'           WHERE Damage_Location IN ('Jim Hallam.', 'Jim Hallam. ');
UPDATE sales_leads SET Damage_Location = 'Derek Savage'         WHERE Damage_Location IN ('Derek Savage.', 'Derek Savage. ');
UPDATE sales_leads SET Damage_Location = 'Kyle Zeller'          WHERE Damage_Location IN ('Kyle Zeller''s agency', 'Kyle Zeller''s agency ', 'Kyle Zeller''s Office');
UPDATE sales_leads SET Damage_Location = 'Keaton Mulder'        WHERE Damage_Location = 'Mulder & Associates';
UPDATE sales_leads SET Damage_Location = 'Jennifer Williamson'  WHERE Damage_Location IN ('Jennifer & Andrew Williamson', 'Williamson & Associates - Andrew');
UPDATE sales_leads SET Damage_Location = 'Nathan Ward'          WHERE Damage_Location LIKE 'Kimberly Ault%';
UPDATE sales_leads SET Damage_Location = 'Sam Digiovanni'       WHERE Damage_Location = 'Sam Digiovani';
UPDATE sales_leads SET Damage_Location = 'Dan Welch'            WHERE Damage_Location LIKE 'Dan Welch  on 40%';
UPDATE sales_leads SET Damage_Location = 'Rob Copeland'         WHERE Damage_Location IN ('Roy Copeland', 'Roy Copeland - Marissa', 'Rob Copeland (Silvia)', 'Rob Copeland (Silvia) ');
UPDATE sales_leads SET Damage_Location = 'Bruce Holiman'        WHERE Damage_Location LIKE 'Mike with Bruce%';
UPDATE sales_leads SET Damage_Location = 'Josh Van Dorn'        WHERE Damage_Location = 'Josh VanDorn';
UPDATE sales_leads SET Damage_Location = 'American Family'      WHERE Job_Name LIKE '2026-2952%';  -- Josh Van Dorn insurance company fix

-- Null out non-agent entries
UPDATE sales_leads SET Damage_Location = NULL
WHERE Damage_Location LIKE 'Roof, Guttering%'
   OR Damage_Location LIKE 'Referred by Andrew Bishop%';
GO


-- ============================================================
-- STEP 4: LEAD SOURCES
--   source_category groups sources for analysis.
--   is_insurance_origin = 1 flags the Insurance Agents
--   source — enables referral chain origin tracking.
--   is_catchall = 1 flags generic CRM catch-all entries.
-- ============================================================
INSERT INTO lead_sources (source_name, source_category, is_insurance_origin, is_catchall)
SELECT DISTINCT
    LTRIM(RTRIM(Lead_Source))           AS source_name,
    CASE
        WHEN Lead_Source = 'Insurance Agents'               THEN 'Insurance'
        WHEN Lead_Source IN ('Referral',
                             'Previous Customer',
                             'Church Friend',
                             'Prior Relationship')          THEN 'Referral'
        WHEN Lead_Source IN ('Internet', 'Facebook',
                             'Truck Sign', 'Yard Sign',
                             'Door Knocking',
                             'Owner Contact')               THEN 'Marketing'
        ELSE                                                     'Other'
    END                                 AS source_category,
    CASE
        WHEN Lead_Source = 'Insurance Agents' THEN 1
        ELSE 0
    END                                 AS is_insurance_origin,
    CASE
        WHEN Lead_Source IN ('ZZ Rarely used',
                             'Other - Describe in comments') THEN 1
        ELSE 0
    END                                 AS is_catchall
FROM sales_leads
WHERE Lead_Source IS NOT NULL;
GO

-- Verify
-- SELECT * FROM lead_sources ORDER BY source_category, source_name;


-- ============================================================
-- STEP 5: SUB LEAD SOURCES
--   Granular breakdown within lead sources.
--   Sourced from Sub_Lead_Source column in leads export.
--   Note: most sources have matching sub source names —
--   the real value is in Internet sub-sources
--   (Google Organic, Website, Angi's List).
-- ============================================================
INSERT INTO sub_lead_sources (sub_source_name, source_id)
SELECT DISTINCT
    LTRIM(RTRIM(sl.Sub_Lead_Source))    AS sub_source_name,
    ls.source_id
FROM sales_leads sl
INNER JOIN lead_sources ls
    ON LTRIM(RTRIM(sl.Lead_Source)) = ls.source_name
WHERE sl.Sub_Lead_Source IS NOT NULL
  AND sl.Lead_Source IS NOT NULL;
GO

-- Add Angi's list — appears in full dataset but not original export
-- Run only if Angi's list not already in lead_sources
IF NOT EXISTS (SELECT 1 FROM lead_sources WHERE source_name = 'Angi''s list')
BEGIN
    INSERT INTO lead_sources (source_name, source_category, is_insurance_origin, is_catchall)
    VALUES ('Angi''s list', 'Marketing', 0, 0);

    INSERT INTO sub_lead_sources (sub_source_name, source_id)
    SELECT 'Angi''s list', source_id
    FROM lead_sources
    WHERE source_name = 'Angi''s list';
END
GO

-- Verify
-- SELECT ss.sub_source_id, ss.sub_source_name, ls.source_name AS parent_source
-- FROM sub_lead_sources ss
-- INNER JOIN lead_sources ls ON ss.source_id = ls.source_id
-- ORDER BY ls.source_name, ss.sub_source_name;


-- ============================================================
-- STEP 6: LEADS
--   Central fact table load. Joins staging to all dimension
--   tables to resolve foreign keys.
--
--   JOIN strategy:
--   - LEFT JOIN on rep, company, agent — nulls acceptable
--     (unassigned leads, non-insurance leads)
--   - INNER JOIN on source — every lead must have a source
--
--   Job number extraction:
--   - CRM format: "2026-3047: Customer Name"
--   - CHARINDEX finds the colon position
--   - LEFT extracts job number, SUBSTRING extracts name
--   - Older records have no job number prefix
--
--   Agent matching:
--   - Applies same dash-stripping as Step 3
--   - "Austin Rolf - Haley" matches to "Austin Rolf"
-- ============================================================
INSERT INTO leads (
    job_number,
    customer_name,
    rep_id,
    source_id,
    company_id,
    agent_id,
    current_milestone,
    contract_total,
    dead_lead_reason
)
SELECT
    -- Extract job number (before colon)
    CASE
        WHEN CHARINDEX(':', sl.Job_Name) > 0
        THEN LTRIM(RTRIM(LEFT(sl.Job_Name, CHARINDEX(':', sl.Job_Name) - 1)))
        ELSE NULL
    END                                             AS job_number,

    -- Extract customer name (after colon, or full value if no colon)
    CASE
        WHEN CHARINDEX(':', sl.Job_Name) > 0
        THEN LTRIM(RTRIM(SUBSTRING(sl.Job_Name,
             CHARINDEX(':', sl.Job_Name) + 1, LEN(sl.Job_Name))))
        ELSE LTRIM(RTRIM(sl.Job_Name))
    END                                             AS customer_name,

    r.rep_id,
    ls.source_id,
    ic.company_id,
    ia.agent_id,
    LTRIM(RTRIM(sl.Current_Milestone))              AS current_milestone,
    ISNULL(sl.Contract_Total, 0)                    AS contract_total,
    LTRIM(RTRIM(sl.Dead_Lead_Reason))               AS dead_lead_reason

FROM sales_leads sl

LEFT JOIN sales_reps r
    ON LTRIM(RTRIM(sl.Primary_Salesperson)) = r.full_name

INNER JOIN lead_sources ls
    ON LTRIM(RTRIM(sl.Lead_Source)) = ls.source_name

LEFT JOIN insurance_companies ic
    ON LOWER(LTRIM(RTRIM(sl.Insurance_Company))) = ic.normalized_name

-- Agent lookup: apply dash-stripping to match cleaned agent names
LEFT JOIN insurance_agents ia
    ON ia.company_id = ic.company_id
    AND ia.agent_name = CASE
        WHEN CHARINDEX('-', LTRIM(RTRIM(sl.Damage_Location))) > 0
        THEN LTRIM(RTRIM(LEFT(sl.Damage_Location,
             CHARINDEX('-', sl.Damage_Location) - 1)))
        ELSE LTRIM(RTRIM(sl.Damage_Location))
    END;
GO

-- Verify
-- SELECT COUNT(*) FROM leads;                          -- expect 567
-- SELECT COUNT(*) FROM leads WHERE company_id IS NULL; -- non-insurance leads
-- SELECT COUNT(*) FROM leads WHERE agent_id IS NOT NULL
--   AND source_id = (SELECT source_id FROM lead_sources
--                    WHERE source_name = 'Insurance Agents');


-- ============================================================
-- STEP 6a: BACKFILL SUB SOURCE IDs
--   Matches sub_source_id from full leads export back to
--   leads loaded from the original export.
--   Note: partial coverage (~51%) — original export did not
--   include Sub_Lead_Source column. Full coverage requires
--   a re-export from CRM with that column included.
-- ============================================================
UPDATE l
SET l.sub_source_id = ss.sub_source_id
FROM leads l
INNER JOIN sales_leads sl
    ON (
        CHARINDEX(':', sl.Job_Name) > 0
        AND l.job_number = LTRIM(RTRIM(LEFT(sl.Job_Name, CHARINDEX(':', sl.Job_Name) - 1)))
    )
    OR (
        CHARINDEX(':', sl.Job_Name) = 0
        AND l.customer_name = LTRIM(RTRIM(sl.Job_Name))
    )
INNER JOIN sub_lead_sources ss
    ON LTRIM(RTRIM(sl.Sub_Lead_Source)) = ss.sub_source_name
    AND ss.source_id = (
        SELECT source_id FROM lead_sources
        WHERE source_name = LTRIM(RTRIM(sl.Lead_Source))
    )
WHERE sl.Sub_Lead_Source IS NOT NULL;
GO

-- Verify
-- SELECT COUNT(sub_source_id) AS populated FROM leads; -- expect ~289


-- ============================================================
-- STEP 7: PIPELINE TIMING
--   One row per lead matching all timing columns from CRM.
--   ABS() handles negative values caused by CRM date entry
--   errors (e.g. milestone dates entered in wrong order).
--   ROW_NUMBER deduplication handles identical staging rows.
--   Tiebreaker on Current_Milestone added to handle leads
--   with same name and source but different milestones
--   (e.g. Meredith Kirby: Prospect + Assigned Lead).
-- ============================================================
INSERT INTO pipeline_timing (
    lead_id,
    lead_days,
    prospect_days,
    lead_to_approved_days,
    approved_days,
    approved_to_invoiced_days,
    approved_to_closed_days,
    completed_days,
    invoiced_days,
    lead_to_closed_days,
    lead_to_dead_days,
    total_process_days
)
SELECT
    l.lead_id,
    ABS(ISNULL(CAST(sl.Lead_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Prospect_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Lead_Prospect_to_Approved_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Approved_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Approved_to_Invoiced_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Approved_to_Closed_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Completed_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Invoiced_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Lead_Prospect_to_Closed_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Lead_Prospect_to_Dead_Days AS INT), 0)),
    ABS(ISNULL(CAST(sl.Total_Process_Time_Days AS INT), 0))
FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY Job_Name, Current_Milestone, Lead_Source
            ORDER BY (SELECT NULL)
        ) AS row_num
    FROM sales_leads
    WHERE Job_Name IS NOT NULL
) sl
INNER JOIN leads l
    ON l.lead_id = (
        SELECT TOP 1 l2.lead_id
        FROM leads l2
        INNER JOIN lead_sources ls2 ON l2.source_id = ls2.source_id
        WHERE
            (
                CHARINDEX(':', sl.Job_Name) > 0
                AND l2.job_number = LTRIM(RTRIM(
                    LEFT(sl.Job_Name, CHARINDEX(':', sl.Job_Name) - 1)))
            )
            OR
            (
                CHARINDEX(':', sl.Job_Name) = 0
                AND l2.customer_name     = LTRIM(RTRIM(sl.Job_Name))
                AND ls2.source_name      = LTRIM(RTRIM(sl.Lead_Source))
                AND l2.current_milestone = LTRIM(RTRIM(sl.Current_Milestone))
            )
        ORDER BY l2.lead_id
    )
WHERE sl.row_num = 1;
GO

-- Verify
-- SELECT COUNT(*) FROM pipeline_timing; -- expect 567


-- ============================================================
-- STEP 8: PAYMENTS
--   Sourced from stg_sales (sales report export).
--   ROW_NUMBER deduplication handles CRM duplicate entries
--   (dead leads frequently duplicated in sales export).
--   TRY_CAST on approved_date safely handles malformed dates.
--   Note: 4 records have negative balance_due (overpayments).
--   These are valid business records — supplemental insurance
--   payments arrived after original contract was written.
-- ============================================================
INSERT INTO payments (
    lead_id,
    approved_date,
    contract_amount,
    payments_received,
    balance_due
)
SELECT
    l.lead_id,
    TRY_CAST(ss.Approved_Date AS DATE)      AS approved_date,
    ISNULL(ss.Contract_Amount, 0)           AS contract_amount,
    ISNULL(ss.Payments_Received, 0)         AS payments_received,
    ISNULL(ss.Balance_Due, 0)               AS balance_due
FROM (
    SELECT
        Contact_Name,
        Current_Milestone,
        Approved_Date,
        Contract_Amount,
        Payments_Received,
        Balance_Due,
        Dead_Lead_Reason,
        Job_Number,
        -- Deduplicate: keep one row per contact + milestone combination
        ROW_NUMBER() OVER (
            PARTITION BY Contact_Name, Current_Milestone
            ORDER BY Job_Number
        ) AS row_num
    FROM stg_sales
    WHERE Contact_Name IS NOT NULL
) ss
INNER JOIN leads l
    ON l.lead_id = (
        SELECT TOP 1 l2.lead_id
        FROM leads l2
        WHERE
            (
                -- Match on job number when available (most reliable)
                CHARINDEX(':', ss.Contact_Name) > 0
                AND l2.job_number = LTRIM(RTRIM(
                    LEFT(ss.Contact_Name, CHARINDEX(':', ss.Contact_Name) - 1)))
            )
            OR
            (
                -- Fall back to name + milestone match
                CHARINDEX(':', ss.Contact_Name) = 0
                AND l2.customer_name     = LTRIM(RTRIM(ss.Contact_Name))
                AND l2.current_milestone = LTRIM(RTRIM(ss.Current_Milestone))
            )
        ORDER BY l2.lead_id
    )
WHERE ss.row_num = 1;
GO

-- Verify
-- SELECT COUNT(*) FROM payments; -- expect 565


-- ============================================================
-- FINAL VALIDATION
--   Run after all steps complete to confirm row counts
--   and cross-table consistency.
-- ============================================================

-- Row count summary
-- SELECT 'sales_reps'          AS table_name, COUNT(*) AS row_count FROM sales_reps
-- UNION ALL
-- SELECT 'insurance_companies',                COUNT(*)             FROM insurance_companies
-- UNION ALL
-- SELECT 'insurance_agents',                   COUNT(*)             FROM insurance_agents
-- UNION ALL
-- SELECT 'lead_sources',                       COUNT(*)             FROM lead_sources
-- UNION ALL
-- SELECT 'sub_lead_sources',                   COUNT(*)             FROM sub_lead_sources
-- UNION ALL
-- SELECT 'leads',                              COUNT(*)             FROM leads
-- UNION ALL
-- SELECT 'pipeline_timing',                    COUNT(*)             FROM pipeline_timing
-- UNION ALL
-- SELECT 'payments',                           COUNT(*)             FROM payments;

-- Expected results:
-- sales_reps          11
-- insurance_companies 10
-- insurance_agents    57
-- lead_sources        14
-- sub_lead_sources    16
-- leads              567
-- pipeline_timing    567
-- payments           565


-- ============================================================
-- END OF ETL
-- ============================================================
