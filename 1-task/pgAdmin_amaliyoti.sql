-- ============================================================================
-- DEAA Lecture 4 — pgAdmin Practical Lab
-- Topic: Star Schema, SCD Type 2, and Analytical Queries in PostgreSQL
-- Student: Muhammadjon Merzaqulov
-- Group: 23-203
-- File: 23-203_Merzaqulov_L4_amaliyot.sql
-- ============================================================================

-- ============================================================================
-- 0. SCHEMA INITIALIZATION
-- Create a clean 'dw' schema and set it as the default search path for the session.
-- Re-running this block drops existing objects in 'dw' to ensure a clean rebuild.
-- ============================================================================
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
SET search_path TO dw;


-- ============================================================================
-- 1. dim_date (One row per calendar day, 2020–2035, with Uzbekistan holidays)
-- Grain: One row per day (2020–2035) + Unknown member row (-1)
-- Key features: Holiday & weekend flags, calendar quarter, surrogate integer key
-- ============================================================================
CREATE TABLE dim_date (
    date_key      INTEGER PRIMARY KEY,           -- Format: YYYYMMDD (e.g., 20261107)
    full_date     DATE NOT NULL UNIQUE,
    day_of_month  SMALLINT NOT NULL,
    day_name      TEXT NOT NULL,
    week_of_year  SMALLINT NOT NULL,
    month_num     SMALLINT NOT NULL,
    month_name    TEXT NOT NULL,
    quarter       SMALLINT NOT NULL,
    year          SMALLINT NOT NULL,
    is_weekend    BOOLEAN NOT NULL,
    is_holiday    BOOLEAN NOT NULL DEFAULT FALSE,
    holiday_name  TEXT
);

-- Insert default unknown member row (-1 key) for missing/unmapped dates
INSERT INTO dim_date (
    date_key, full_date, day_of_month, day_name, week_of_year,
    month_num, month_name, quarter, year, is_weekend, is_holiday, holiday_name
) VALUES (
    -1, DATE '1900-01-01', 1, 'Noma''lum', 1,
    1, 'Noma''lum', 1, 1900, FALSE, FALSE, NULL
);

-- Populate 16 years of calendar dates (2020-01-01 through 2035-12-31) using generate_series()
INSERT INTO dim_date (
    date_key,
    full_date,
    day_of_month,
    day_name,
    week_of_year,
    month_num,
    month_name,
    quarter,
    year,
    is_weekend
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER   AS date_key,
    d::DATE                           AS full_date,
    EXTRACT(DAY FROM d)::SMALLINT     AS day_of_month,
    TRIM(TO_CHAR(d, 'Day'))           AS day_name,
    EXTRACT(WEEK FROM d)::SMALLINT    AS week_of_year,
    EXTRACT(MONTH FROM d)::SMALLINT   AS month_num,
    TRIM(TO_CHAR(d, 'Month'))         AS month_name,
    EXTRACT(QUARTER FROM d)::SMALLINT AS quarter,
    EXTRACT(YEAR FROM d)::SMALLINT    AS year,
    CASE WHEN EXTRACT(ISODOW FROM d) IN (6, 7) THEN TRUE ELSE FALSE END AS is_weekend
FROM generate_series(DATE '2020-01-01', DATE '2035-12-31', INTERVAL '1 day') AS gs(d);

-- Flag fixed-date official public holidays in Uzbekistan
UPDATE dim_date
SET is_holiday = TRUE,
    holiday_name = CASE
        WHEN month_num = 1  AND day_of_month = 1  THEN 'Yangi yil bayrami'
        WHEN month_num = 3  AND day_of_month = 8  THEN 'Xalqaro xotin-qizlar kuni'
        WHEN month_num = 3  AND day_of_month = 21 THEN 'Navro''z bayrami'
        WHEN month_num = 5  AND day_of_month = 9  THEN 'Xotira va qadrlash kuni'
        WHEN month_num = 9  AND day_of_month = 1  THEN 'Mustaqillik kuni'
        WHEN month_num = 10 AND day_of_month = 1  THEN 'O''qituvchi va murabbiylar kuni'
        WHEN month_num = 12 AND day_of_month = 8  THEN 'Konstitutsiya kuni'
    END
WHERE (month_num = 1  AND day_of_month = 1)
   OR (month_num = 3  AND day_of_month = 8)
   OR (month_num = 3  AND day_of_month = 21)
   OR (month_num = 5  AND day_of_month = 9)
   OR (month_num = 9  AND day_of_month = 1)
   OR (month_num = 10 AND day_of_month = 1)
   OR (month_num = 12 AND day_of_month = 8);

-- Flag variable-date religious holidays (Ramazon hayiti & Qurbon hayiti for 2025–2026)
UPDATE dim_date SET is_holiday = TRUE, holiday_name = 'Ramazon hayiti'
WHERE full_date IN (DATE '2025-03-30', DATE '2026-03-20');

UPDATE dim_date SET is_holiday = TRUE, holiday_name = 'Qurbon hayiti'
WHERE full_date IN (DATE '2025-06-06', DATE '2026-05-27');


-- ============================================================================
-- 2. dim_store (One row per store version — SCD Type 2)
-- Grain: One row per store version
-- Key features: SCD Type 2 tracking on 'format'; 'store_code' is the natural key
-- ============================================================================
CREATE TABLE dim_store (
    store_key        SERIAL PRIMARY KEY,
    store_code       TEXT NOT NULL,              -- Natural business key (e.g., 'STR-001')
    store_name       TEXT NOT NULL,
    city             TEXT NOT NULL,
    region           TEXT NOT NULL,
    format           TEXT NOT NULL,              -- SCD Type 2 tracked attribute ('Minimarket', 'Supermarket', 'Hypermarket')
    effective_from   DATE NOT NULL,
    effective_to     DATE NOT NULL DEFAULT DATE '9999-12-31',
    is_current       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_store_dates CHECK (effective_to >= effective_from)
);

-- Enforce that only one active (is_current = TRUE) version exists per natural key
CREATE UNIQUE INDEX uq_dim_store_current
    ON dim_store (store_code)
    WHERE is_current = TRUE;

-- Insert default unknown store row (-1 key)
INSERT INTO dim_store (
    store_key, store_code, store_name, city, region, format,
    effective_from, effective_to, is_current
) VALUES (
    -1, 'UNKNOWN', 'Noma''lum do''kon', 'Noma''lum', 'Noma''lum', 'Noma''lum',
    DATE '1900-01-01', DATE '9999-12-31', TRUE
);

-- Seed initial store dimension records
INSERT INTO dim_store (
    store_code, store_name, city, region, format,
    effective_from, effective_to, is_current
) VALUES
    ('STR-001', 'Chilonzor filiali',  'Toshkent',  'Toshkent shahri',    'Minimarket',  DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('STR-002', 'Yunusobod filiali',  'Toshkent',  'Toshkent shahri',    'Supermarket', DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('STR-003', 'Registon filiali',   'Samarqand', 'Samarqand viloyati', 'Supermarket', DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('STR-004', 'Buxoro Markaz',      'Buxoro',    'Buxoro viloyati',    'Minimarket',  DATE '2024-06-01', DATE '9999-12-31', TRUE);


-- ============================================================================
-- 3. dim_product (One row per product version — SCD Type 2)
-- Grain: One row per product version
-- Key features: SCD Type 2 tracking on 'category'
-- ============================================================================
CREATE TABLE dim_product (
    product_key      SERIAL PRIMARY KEY,
    product_code     TEXT NOT NULL,              -- Natural business key (e.g., 'PRD-101')
    product_name     TEXT NOT NULL,
    brand            TEXT NOT NULL,
    category         TEXT NOT NULL,              -- SCD Type 2 tracked attribute
    unit_cost        NUMERIC(12, 2) NOT NULL CHECK (unit_cost >= 0),
    list_price       NUMERIC(12, 2) NOT NULL CHECK (list_price >= 0),
    effective_from   DATE NOT NULL,
    effective_to     DATE NOT NULL DEFAULT DATE '9999-12-31',
    is_current       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_product_dates CHECK (effective_to >= effective_from)
);

-- Enforce a single current version per product_code
CREATE UNIQUE INDEX uq_dim_product_current
    ON dim_product (product_code)
    WHERE is_current = TRUE;

-- Insert default unknown product row (-1 key)
INSERT INTO dim_product (
    product_key, product_code, product_name, brand, category,
    unit_cost, list_price, effective_from, effective_to, is_current
) VALUES (
    -1, 'UNKNOWN', 'Noma''lum mahsulot', 'Noma''lum', 'Noma''lum',
    0.00, 0.00, DATE '1900-01-01', DATE '9999-12-31', TRUE
);

-- Seed initial product dimension records
INSERT INTO dim_product (
    product_code, product_name, brand, category,
    unit_cost, list_price, effective_from, effective_to, is_current
) VALUES
    ('PRD-101', 'Tabiiy sut 1L',         'Musaffo',  'Sut mahsulotlari', 9000.00,  12000.00, DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('PRD-102', 'Qora shokolad 100g',    'Milliy',   'Shirinliklar',     14000.00, 19000.00, DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('PRD-103', 'Ko''k choy 200g',       'Impra',    'Ichimliklar',      18000.00, 25000.00, DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('PRD-104', 'Suli yormasi 500g',     'Hercules', 'Bakaleya',         11000.00, 16000.00, DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('PRD-105', 'Protein batonchik 60g', 'FitBar',   'Shirinliklar',     15000.00, 22000.00, DATE '2024-01-01', DATE '9999-12-31', TRUE);


-- ============================================================================
-- 4. dim_customer (One row per customer version — Hybrid SCD Type 1 & Type 2)
-- Grain: One row per customer version
-- Key features: SCD Type 2 on 'region' and 'loyalty_tier';
--               SCD Type 1 (overwrite) on 'phone';
--               Special keys: -1 (Unknown) and 0 (Guest / Unregistered customer)
-- ============================================================================
CREATE TABLE dim_customer (
    customer_key     SERIAL PRIMARY KEY,
    customer_code    TEXT NOT NULL,              -- Natural business key (e.g., 'CUST-001')
    full_name        TEXT NOT NULL,
    phone            TEXT NOT NULL,              -- SCD Type 1 attribute (overwritten in-place)
    region           TEXT NOT NULL,              -- SCD Type 2 attribute (triggers new row version)
    loyalty_tier     TEXT NOT NULL,              -- SCD Type 2 attribute ('Standard', 'Silver', 'Gold', 'Platinum')
    effective_from   DATE NOT NULL,
    effective_to     DATE NOT NULL DEFAULT DATE '9999-12-31',
    is_current       BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_customer_dates CHECK (effective_to >= effective_from)
);

-- Enforce a single current version per customer_code
CREATE UNIQUE INDEX uq_dim_customer_current
    ON dim_customer (customer_code)
    WHERE is_current = TRUE;

-- Insert special member rows: -1 (Unknown customer) and 0 (Unregistered / Guest checkout)
INSERT INTO dim_customer (
    customer_key, customer_code, full_name, phone, region, loyalty_tier,
    effective_from, effective_to, is_current
) VALUES
    (-1, 'UNKNOWN', 'Noma''lum mijoz',            'N/A', 'Noma''lum', 'None', DATE '1900-01-01', DATE '9999-12-31', TRUE),
    ( 0, 'GUEST',   'Ro''yxatdan o''tmagan mijoz', 'N/A', 'Noma''lum', 'None', DATE '1900-01-01', DATE '9999-12-31', TRUE);

-- Seed initial customer dimension records
INSERT INTO dim_customer (
    customer_code, full_name, phone, region, loyalty_tier,
    effective_from, effective_to, is_current
) VALUES
    ('CUST-001', 'Aliyev Sardor',    '+998901112233', 'Toshkent shahri',    'Silver',   DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('CUST-002', 'Karimova Nilufar', '+998934445566', 'Samarqand viloyati', 'Standard', DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('CUST-003', 'Ergashev Bobur',   '+998977778899', 'Buxoro viloyati',    'Gold',     DATE '2024-01-01', DATE '9999-12-31', TRUE),
    ('CUST-004', 'Rahimova Dilnoza', '+998991234567', 'Toshkent shahri',    'Standard', DATE '2025-01-15', DATE '9999-12-31', TRUE);


-- ============================================================================
-- 5. fact_sales (One row per receipt line item)
-- Grain: Individual receipt line item
-- Key features: Surrogate foreign keys + numeric additive measures only;
--               'receipt_no' as degenerate dimension; UNIQUE(receipt_no, line_no)
-- ============================================================================
CREATE TABLE fact_sales (
    sales_key        BIGSERIAL PRIMARY KEY,
    date_key         INTEGER NOT NULL DEFAULT -1 REFERENCES dim_date(date_key),
    store_key        INTEGER NOT NULL DEFAULT -1 REFERENCES dim_store(store_key),
    product_key      INTEGER NOT NULL DEFAULT -1 REFERENCES dim_product(product_key),
    customer_key     INTEGER NOT NULL DEFAULT  0 REFERENCES dim_customer(customer_key),
    receipt_no       TEXT NOT NULL,              -- Degenerate dimension (POS receipt identifier)
    line_no          SMALLINT NOT NULL,          -- Receipt line sequence number
    quantity         NUMERIC(10, 2) NOT NULL CHECK (quantity > 0),
    unit_price       NUMERIC(12, 2) NOT NULL CHECK (unit_price >= 0),
    discount_amount  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (discount_amount >= 0),
    net_sales_amount NUMERIC(12, 2) NOT NULL CHECK (net_sales_amount >= 0),
    cost_amount      NUMERIC(12, 2) NOT NULL CHECK (cost_amount >= 0),
    CONSTRAINT uq_fact_sales_receipt_line UNIQUE (receipt_no, line_no)
);


-- ============================================================================
-- 6. APPLYING SCD TYPE 1 AND SCD TYPE 2 DIMENSION UPDATES
-- ============================================================================

-- 6.1. dim_store SCD Type 2:
--      Store 'STR-001' expanded from 'Minimarket' to 'Supermarket' on 2025-06-01.
--      Expire the active row on 2025-05-31 and insert a new current version.
BEGIN;

UPDATE dim_store
SET effective_to = DATE '2025-05-31',
    is_current   = FALSE
WHERE store_code = 'STR-001'
  AND is_current = TRUE;

INSERT INTO dim_store (
    store_code, store_name, city, region, format,
    effective_from, effective_to, is_current
) VALUES (
    'STR-001', 'Chilonzor filiali', 'Toshkent', 'Toshkent shahri', 'Supermarket',
    DATE '2025-06-01', DATE '9999-12-31', TRUE
);

COMMIT;

-- 6.2. dim_product SCD Type 2:
--      Product 'PRD-105' ('Protein batonchik 60g') was reclassified from
--      'Shirinliklar' to 'Sog''lom ovqatlanish' on 2025-09-01.
BEGIN;

UPDATE dim_product
SET effective_to = DATE '2025-08-31',
    is_current   = FALSE
WHERE product_code = 'PRD-105'
  AND is_current   = TRUE;

INSERT INTO dim_product (
    product_code, product_name, brand, category,
    unit_cost, list_price, effective_from, effective_to, is_current
) VALUES (
    'PRD-105', 'Protein batonchik 60g', 'FitBar', 'Sog''lom ovqatlanish',
    15000.00, 22000.00, DATE '2025-09-01', DATE '9999-12-31', TRUE
);

COMMIT;

-- 6.3. dim_customer Hybrid SCD updates:
--      a) SCD Type 1: Customer 'CUST-001' updated their phone number (overwritten across all versions)
UPDATE dim_customer
SET phone = '+998909998877'
WHERE customer_code = 'CUST-001';

--      b) SCD Type 2: Customer 'CUST-001' was upgraded from 'Silver' to 'Gold' tier on 2025-07-01
BEGIN;

UPDATE dim_customer
SET effective_to = DATE '2025-06-30',
    is_current   = FALSE
WHERE customer_code = 'CUST-001'
  AND is_current    = TRUE;

INSERT INTO dim_customer (
    customer_code, full_name, phone, region, loyalty_tier,
    effective_from, effective_to, is_current
)
SELECT
    'CUST-001', full_name, phone, region, 'Gold',
    DATE '2025-07-01', DATE '9999-12-31', TRUE
FROM dim_customer
WHERE customer_code = 'CUST-001'
  AND effective_to  = DATE '2025-06-30';

COMMIT;


-- ============================================================================
-- 7. LOADING HISTORICAL AND CURRENT TRANSACTIONS INTO fact_sales
-- Point-in-time surrogate key lookup: matches transaction date against
-- dimension [effective_from, effective_to] windows to preserve historical truth.
-- ============================================================================
WITH raw_sales (
    sale_date, store_code, product_code, customer_code,
    receipt_no, line_no, quantity, discount_amount
) AS (
    VALUES
        -- Transactions on 2025-03-21 (Navro'z holiday): STR-001 is still 'Minimarket',
        -- PRD-105 is still 'Shirinliklar', and CUST-001 is still 'Silver'
        (DATE '2025-03-21', 'STR-001', 'PRD-101', 'CUST-001', 'RCP-2025-0001', 1, 2,    0.00),
        (DATE '2025-03-21', 'STR-001', 'PRD-105', 'CUST-001', 'RCP-2025-0001', 2, 3, 3000.00),
        -- Transactions on 2025-09-01 (Independence Day): STR-001 is now 'Supermarket',
        -- PRD-105 is now 'Sog''lom ovqatlanish', and CUST-001 is now 'Gold'
        (DATE '2025-09-01', 'STR-001', 'PRD-105', 'CUST-001', 'RCP-2025-0002', 1, 5, 5000.00),
        (DATE '2025-09-01', 'STR-001', 'PRD-103', 'CUST-001', 'RCP-2025-0002', 2, 1,    0.00),
        -- Registered customer transaction at Samarkand store
        (DATE '2025-10-01', 'STR-003', 'PRD-102', 'CUST-002', 'RCP-2025-0003', 1, 4, 4000.00),
        -- Anonymous guest checkout (maps to customer_key = 0)
        (DATE '2026-01-01', 'STR-002', 'PRD-104', 'GUEST',    'RCP-2026-0001', 1, 2,    0.00)
)
INSERT INTO fact_sales (
    date_key, store_key, product_key, customer_key,
    receipt_no, line_no, quantity, unit_price, discount_amount, net_sales_amount, cost_amount
)
SELECT
    COALESCE(d.date_key, -1)                                     AS date_key,
    COALESCE(s.store_key, -1)                                    AS store_key,
    COALESCE(p.product_key, -1)                                  AS product_key,
    COALESCE(c.customer_key, 0)                                  AS customer_key,
    r.receipt_no,
    r.line_no,
    r.quantity,
    p.list_price                                                 AS unit_price,
    r.discount_amount,
    (r.quantity * p.list_price) - r.discount_amount              AS net_sales_amount,
    (r.quantity * p.unit_cost)                                   AS cost_amount
FROM raw_sales r
LEFT JOIN dim_date d
       ON d.full_date = r.sale_date
LEFT JOIN dim_store s
       ON s.store_code = r.store_code
      AND r.sale_date BETWEEN s.effective_from AND s.effective_to
LEFT JOIN dim_product p
       ON p.product_code = r.product_code
      AND r.sale_date BETWEEN p.effective_from AND p.effective_to
LEFT JOIN dim_customer c
       ON c.customer_code = r.customer_code
      AND r.sale_date BETWEEN c.effective_from AND c.effective_to;


-- ============================================================================
-- 8. ANALYTICAL QUERIES (STAR SCHEMA & SCD TYPE 2 ANALYSIS)
-- ============================================================================

-- 8.1. Revenue and gross profit by store format at the time of sale
--      Demonstrates SCD Type 2 partitioning for 'STR-001' across 'Minimarket' and 'Supermarket'
SELECT
    s.store_code,
    s.store_name,
    s.format                                      AS store_format_at_sale,
    COUNT(DISTINCT f.receipt_no)                  AS receipts_count,
    SUM(f.quantity)                               AS total_qty,
    SUM(f.net_sales_amount)                       AS total_net_sales,
    SUM(f.net_sales_amount - f.cost_amount)       AS gross_profit
FROM fact_sales f
JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.store_code, s.store_name, s.format
ORDER BY s.store_code, store_format_at_sale;

-- 8.2. Historical vs. current revenue by product category
--      Product 'PRD-105' accurately attributes revenue to both old and new categories
SELECT
    p.product_code,
    p.product_name,
    p.category                                    AS category_at_sale,
    SUM(f.quantity)                               AS units_sold,
    SUM(f.net_sales_amount)                       AS net_revenue
FROM fact_sales f
JOIN dim_product p ON p.product_key = f.product_key
GROUP BY p.product_code, p.product_name, p.category
ORDER BY p.product_code, category_at_sale;

-- 8.3. Customer spending breakdown by loyalty tier at the time of purchase
--      Also shows the updated SCD Type 1 phone number across all historical records
SELECT
    c.customer_code,
    c.full_name,
    c.phone,
    c.loyalty_tier                                AS tier_at_sale,
    COUNT(DISTINCT f.receipt_no)                  AS orders_count,
    SUM(f.net_sales_amount)                       AS total_spent
FROM fact_sales f
JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.customer_code, c.full_name, c.phone, c.loyalty_tier
ORDER BY c.customer_code, tier_at_sale;

-- 8.4. Holiday vs. regular day sales performance
SELECT
    d.year,
    d.is_holiday,
    COALESCE(d.holiday_name, 'Regular Day')       AS day_type,
    COUNT(DISTINCT f.receipt_no)                  AS total_receipts,
    SUM(f.net_sales_amount)                       AS net_revenue
FROM fact_sales f
JOIN dim_date d ON d.date_key = f.date_key
GROUP BY d.year, d.is_holiday, COALESCE(d.holiday_name, 'Regular Day')
ORDER BY d.year, net_revenue DESC;


-- ============================================================================
-- 9. INDEXING AND EXPLAIN ANALYZE PERFORMANCE COMPARISON
-- Note: In pgAdmin, press F7 (Explain > Analyze) to inspect execution plans
--       and compare execution time before and after creating indexes.
-- ============================================================================

-- 9.1. Generate 50,000 synthetic line items in fact_sales for realistic benchmarking
INSERT INTO fact_sales (
    date_key, store_key, product_key, customer_key,
    receipt_no, line_no, quantity, unit_price, discount_amount, net_sales_amount, cost_amount
)
SELECT
    TO_CHAR(DATE '2024-01-01' + ((gs % 730) * INTERVAL '1 day'), 'YYYYMMDD')::INTEGER AS date_key,
    (gs % 4) + 1                                              AS store_key,
    (gs % 5) + 1                                              AS product_key,
    CASE WHEN gs % 5 = 0 THEN 0 ELSE (gs % 4) + 1 END         AS customer_key,
    'RCP-BULK-' || LPAD(((gs - 1) / 3 + 1)::TEXT, 6, '0')     AS receipt_no,
    (((gs - 1) % 3) + 1)::SMALLINT                            AS line_no,
    ((gs % 5) + 1)::NUMERIC(10, 2)                            AS quantity,
    15000.00                                                  AS unit_price,
    0.00                                                      AS discount_amount,
    (((gs % 5) + 1) * 15000.00)::NUMERIC(12, 2)               AS net_sales_amount,
    (((gs % 5) + 1) * 10000.00)::NUMERIC(12, 2)               AS cost_amount
FROM generate_series(1, 50000) AS gs
ON CONFLICT (receipt_no, line_no) DO NOTHING;

ANALYZE fact_sales;

-- 9.2. Check execution plan BEFORE creating foreign key indexes (Seq Scan on fact_sales)
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    d.year,
    d.quarter,
    s.region,
    p.category,
    SUM(f.net_sales_amount)                 AS total_revenue,
    SUM(f.net_sales_amount - f.cost_amount) AS total_profit
FROM fact_sales f
JOIN dim_date d    ON d.date_key    = f.date_key
JOIN dim_store s   ON s.store_key   = f.store_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE d.year = 2025
  AND d.quarter = 3
  AND f.store_key = 2
GROUP BY d.year, d.quarter, s.region, p.category;

-- 9.3. Create B-Tree indexes on foreign keys and composite analytical filter columns
CREATE INDEX idx_fact_sales_date_key     ON fact_sales (date_key);
CREATE INDEX idx_fact_sales_store_key    ON fact_sales (store_key);
CREATE INDEX idx_fact_sales_product_key  ON fact_sales (product_key);
CREATE INDEX idx_fact_sales_customer_key ON fact_sales (customer_key);
CREATE INDEX idx_fact_sales_date_store   ON fact_sales (date_key, store_key);

ANALYZE fact_sales;

-- 9.4. Check execution plan AFTER creating indexes (Bitmap Index Scan / Index Scan)
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    d.year,
    d.quarter,
    s.region,
    p.category,
    SUM(f.net_sales_amount)                 AS total_revenue,
    SUM(f.net_sales_amount - f.cost_amount) AS total_profit
FROM fact_sales f
JOIN dim_date d    ON d.date_key    = f.date_key
JOIN dim_store s   ON s.store_key   = f.store_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE d.year = 2025
  AND d.quarter = 3
  AND f.store_key = 2
GROUP BY d.year, d.quarter, s.region, p.category;


-- ============================================================================
-- 10. STUDENT TASKS (INDEPENDENT EXERCISES)
-- ============================================================================

-- Task 1: Implement SCD Type 2 version transition for a customer relocation & tier upgrade
-- Requirement: Customer 'CUST-002' ('Karimova Nilufar') relocated from
--              'Samarqand viloyati' to 'Toshkent shahri' and upgraded to 'Silver' on 2026-02-01.
BEGIN;

UPDATE dim_customer
SET effective_to = DATE '2026-01-31',
    is_current   = FALSE
WHERE customer_code = 'CUST-002'
  AND is_current    = TRUE;

INSERT INTO dim_customer (
    customer_code, full_name, phone, region, loyalty_tier,
    effective_from, effective_to, is_current
)
SELECT
    'CUST-002', full_name, phone, 'Toshkent shahri', 'Silver',
    DATE '2026-02-01', DATE '9999-12-31', TRUE
FROM dim_customer
WHERE customer_code = 'CUST-002'
  AND effective_to  = DATE '2026-01-31';

COMMIT;

-- Task 2: Calculate quarterly revenue, gross profit, and Quarter-over-Quarter (QoQ %) growth
WITH quarterly_sales AS (
    SELECT
        d.year,
        d.quarter,
        SUM(f.net_sales_amount)                 AS revenue,
        SUM(f.net_sales_amount - f.cost_amount) AS profit
    FROM fact_sales f
    JOIN dim_date d ON d.date_key = f.date_key
    WHERE d.date_key <> -1
    GROUP BY d.year, d.quarter
)
SELECT
    year,
    quarter,
    revenue,
    profit,
    LAG(revenue) OVER (ORDER BY year, quarter) AS prev_quarter_revenue,
    ROUND(
        100.0 * (revenue - LAG(revenue) OVER (ORDER BY year, quarter))
        / NULLIF(LAG(revenue) OVER (ORDER BY year, quarter), 0),
        2
    ) AS qoq_growth_pct
FROM quarterly_sales
ORDER BY year, quarter;

-- Task 3: Find the Top 3 revenue-generating products within each store format using DENSE_RANK()
WITH ranked_products AS (
    SELECT
        s.format                                AS store_format,
        p.product_code,
        p.product_name,
        p.category,
        SUM(f.net_sales_amount)                 AS total_revenue,
        DENSE_RANK() OVER (
            PARTITION BY s.format
            ORDER BY SUM(f.net_sales_amount) DESC
        ) AS rnk
    FROM fact_sales f
    JOIN dim_store s   ON s.store_key   = f.store_key
    JOIN dim_product p ON p.product_key = f.product_key
    GROUP BY s.format, p.product_code, p.product_name, p.category
)
SELECT
    store_format,
    rnk,
    product_code,
    product_name,
    category,
    total_revenue
FROM ranked_products
WHERE rnk <= 3
ORDER BY store_format, rnk;

-- Task 4: Data Quality & SCD Integrity Audit Query
-- Verify that no dimension table has more than one active (is_current = TRUE) row per natural key
SELECT 'dim_store' AS table_name, store_code AS natural_key, COUNT(*) AS active_versions
FROM dim_store WHERE is_current = TRUE GROUP BY store_code HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_product', product_code, COUNT(*)
FROM dim_product WHERE is_current = TRUE GROUP BY product_code HAVING COUNT(*) > 1
UNION ALL
SELECT 'dim_customer', customer_code, COUNT(*)
FROM dim_customer WHERE is_current = TRUE GROUP BY customer_code HAVING COUNT(*) > 1;