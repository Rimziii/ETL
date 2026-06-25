-- All table definitions for staging, clean, and reporting layers
-- Enable compression and parallel processing
ALTER SESSION SET DB_RECOVERY_FILE_DEST_SIZE=50G;

-- ============================================================================
-- PART 1: LOGGING & INFRASTRUCTURE TABLES
-- ============================================================================

-- Error Log Table
CREATE TABLE error_log (
    error_id NUMBER GENERATED ALWAYS AS IDENTITY,
    procedure_name VARCHAR2(100),
    error_code VARCHAR2(20),
    error_message VARCHAR2(1000),
    error_context VARCHAR2(500),
    record_count NUMBER,
    error_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP,
    status VARCHAR2(20), -- RESOLVED, PENDING, IGNORED
    notes VARCHAR2(500),
    created_by VARCHAR2(50) DEFAULT USER,
    PRIMARY KEY (error_id)
) COMPRESS;

-- Audit Log Table
CREATE TABLE audit_log (
    audit_id NUMBER GENERATED ALWAYS AS IDENTITY,
    procedure_name VARCHAR2(100),
    action VARCHAR2(50), -- INSERT, UPDATE, DELETE, TRUNCATE
    table_name VARCHAR2(100),
    records_affected NUMBER,
    execution_start TIMESTAMP,
    execution_end TIMESTAMP,
    duration_seconds NUMBER,
    status VARCHAR2(20), -- SUCCESS, FAILURE, PARTIAL
    created_by VARCHAR2(50) DEFAULT USER,
    PRIMARY KEY (audit_id)
) COMPRESS;

-- Run Statistics Table
CREATE TABLE run_statistics (
    run_id NUMBER GENERATED ALWAYS AS IDENTITY,
    run_date DATE DEFAULT TRUNC(SYSDATE),
    run_time TIMESTAMP DEFAULT SYSTIMESTAMP,
    run_type VARCHAR2(50), -- FULL, INCREMENTAL, BACKFILL
    
    stg_customers_loaded NUMBER,
    stg_orders_loaded NUMBER,
    stg_products_loaded NUMBER,
    
    clean_customers_transformed NUMBER,
    clean_orders_transformed NUMBER,
    clean_products_transformed NUMBER,
    
    fact_sales_records NUMBER,
    dim_customer_records NUMBER,
    dim_product_records NUMBER,
    
    total_errors NUMBER,
    total_warnings NUMBER,
    total_duration_minutes NUMBER(8,2),
    
    next_run_date DATE,
    pipeline_status VARCHAR2(20), -- SUCCESS, FAILURE, WARNING
    notes VARCHAR2(500),
    PRIMARY KEY (run_id)
) COMPRESS;

-- Data Quality Metrics
CREATE TABLE data_quality_metrics (
    quality_id NUMBER GENERATED ALWAYS AS IDENTITY,
    check_date DATE DEFAULT TRUNC(SYSDATE),
    table_name VARCHAR2(100),
    check_name VARCHAR2(100),
    records_checked NUMBER,
    records_passed NUMBER,
    records_failed NUMBER,
    pass_percentage NUMBER(5,2),
    status VARCHAR2(20), -- PASS, FAIL, WARNING
    notes VARCHAR2(500),
    PRIMARY KEY (quality_id)
) COMPRESS;

-- ============================================================================
-- PART 2: STAGING LAYER (Raw Data)
-- ============================================================================

-- Staging: Customers
CREATE TABLE stg_customers (
    stg_customer_id NUMBER,
    customer_name VARCHAR2(200),
    email VARCHAR2(200),
    phone VARCHAR2(20),
    address VARCHAR2(500),
    city VARCHAR2(100),
    state VARCHAR2(50),
    zip_code VARCHAR2(20),
    country VARCHAR2(100),
    customer_type VARCHAR2(50), -- RETAIL, WHOLESALE, ENTERPRISE
    source_system VARCHAR2(50), -- CRM_SALESFORCE, ERP_SAP, etc
    source_id VARCHAR2(100), -- Original ID from source
    load_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP,
    is_active VARCHAR2(1) DEFAULT 'Y',
    batch_id NUMBER
) COMPRESS;

-- Staging: Orders
CREATE TABLE stg_orders (
    stg_order_id NUMBER,
    order_id VARCHAR2(50),
    customer_id VARCHAR2(50),
    product_id VARCHAR2(50),
    order_date DATE,
    order_quantity NUMBER(10,0),
    unit_price NUMBER(12,2),
    total_amount NUMBER(12,2),
    discount_percent NUMBER(5,2),
    tax_amount NUMBER(12,2),
    status VARCHAR2(50), -- PENDING, COMPLETED, CANCELLED
    payment_method VARCHAR2(50),
    source_system VARCHAR2(50),
    source_id VARCHAR2(100),
    load_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP,
    batch_id NUMBER
) COMPRESS;

-- Staging: Products
CREATE TABLE stg_products (
    stg_product_id NUMBER,
    product_id VARCHAR2(50),
    product_name VARCHAR2(300),
    category VARCHAR2(100),
    subcategory VARCHAR2(100),
    unit_cost NUMBER(12,2),
    unit_price NUMBER(12,2),
    supplier_id VARCHAR2(50),
    is_discontinued VARCHAR2(1) DEFAULT 'N',
    source_system VARCHAR2(50),
    source_id VARCHAR2(100),
    load_timestamp TIMESTAMP DEFAULT SYSTIMESTAMP,
    batch_id NUMBER
) COMPRESS;

-- Staging Indexes
CREATE INDEX idx_stg_cust_source ON stg_customers(source_system, source_id);
CREATE INDEX idx_stg_ord_date ON stg_orders(order_date);
CREATE INDEX idx_stg_prod_cat ON stg_products(category);

-- ============================================================================
-- PART 3: CLEAN LAYER (Transformed Data)
-- ============================================================================

-- Clean: Customers
CREATE TABLE clean_customers (
    clean_customer_id NUMBER GENERATED ALWAYS AS IDENTITY,
    source_customer_id VARCHAR2(50),
    customer_name VARCHAR2(200),
    email VARCHAR2(200),
    email_valid VARCHAR2(1), -- Y/N validation flag
    phone VARCHAR2(20),
    phone_valid VARCHAR2(1),
    address VARCHAR2(500),
    city VARCHAR2(100),
    state VARCHAR2(50),
    zip_code VARCHAR2(20),
    country VARCHAR2(100),
    customer_type VARCHAR2(50),
    customer_type_standardized VARCHAR2(50), -- Standardized values
    source_system VARCHAR2(50),
    is_active VARCHAR2(1),
    created_date DATE,
    last_updated TIMESTAMP DEFAULT SYSTIMESTAMP,
    data_quality_score NUMBER(3,0), -- 0-100
    PRIMARY KEY (clean_customer_id)
) COMPRESS;

-- Clean: Orders
CREATE TABLE clean_orders (
    clean_order_id NUMBER GENERATED ALWAYS AS IDENTITY,
    source_order_id VARCHAR2(50),
    clean_customer_id NUMBER,
    product_id VARCHAR2(50),
    order_date DATE,
    order_month NUMBER(2),
    order_year NUMBER(4),
    order_quantity NUMBER(10,0),
    unit_price NUMBER(12,2),
    total_amount NUMBER(12,2),
    discount_percent NUMBER(5,2),
    discount_amount NUMBER(12,2),
    net_amount NUMBER(12,2),
    tax_amount NUMBER(12,2),
    final_amount NUMBER(12,2),
    status_code VARCHAR2(20),
    status_description VARCHAR2(100),
    payment_method VARCHAR2(50),
    source_system VARCHAR2(50),
    is_duplicate VARCHAR2(1) DEFAULT 'N',
    created_date DATE,
    last_updated TIMESTAMP DEFAULT SYSTIMESTAMP,
    PRIMARY KEY (clean_order_id),
    FOREIGN KEY (clean_customer_id) REFERENCES clean_customers(clean_customer_id)
) COMPRESS PARTITION BY RANGE (order_date) (
    PARTITION part_2023 VALUES LESS THAN (TO_DATE('2024-01-01','YYYY-MM-DD')),
    PARTITION part_2024 VALUES LESS THAN (TO_DATE('2025-01-01','YYYY-MM-DD')),
    PARTITION part_future VALUES LESS THAN (MAXVALUE)
);

-- Clean: Products
CREATE TABLE clean_products (
    clean_product_id NUMBER GENERATED ALWAYS AS IDENTITY,
    source_product_id VARCHAR2(50),
    product_name VARCHAR2(300),
    category VARCHAR2(100),
    category_standardized VARCHAR2(100),
    subcategory VARCHAR2(100),
    unit_cost NUMBER(12,2),
    unit_price NUMBER(12,2),
    cost_valid VARCHAR2(1), -- Cost > 0 validation
    price_valid VARCHAR2(1), -- Price > Cost validation
    margin_percent NUMBER(5,2),
    supplier_id VARCHAR2(50),
    is_discontinued VARCHAR2(1),
    created_date DATE,
    last_updated TIMESTAMP DEFAULT SYSTIMESTAMP,
    PRIMARY KEY (clean_product_id)
) COMPRESS;

-- Clean Indexes
CREATE INDEX idx_clean_cust_source ON clean_customers(source_customer_id);
CREATE INDEX idx_clean_ord_date ON clean_orders(order_date);
CREATE INDEX idx_clean_ord_cust ON clean_orders(clean_customer_id);
CREATE INDEX idx_clean_prod_cat ON clean_products(category_standardized);

-- ============================================================================
-- PART 4: REPORTING LAYER (Fact & Dimension Tables)
-- ============================================================================

-- Dimension: Date (Pre-populated)
CREATE TABLE dim_date (
    date_id NUMBER PRIMARY KEY,
    date_value DATE,
    day_of_week VARCHAR2(10),
    day_of_month NUMBER(2),
    month_num NUMBER(2),
    month_name VARCHAR2(10),
    quarter_num NUMBER(1),
    year_num NUMBER(4),
    fiscal_quarter VARCHAR2(10),
    fiscal_year NUMBER(4),
    is_weekend VARCHAR2(1),
    is_holiday VARCHAR2(1),
    holiday_name VARCHAR2(100)
) COMPRESS;

-- Dimension: Customer
CREATE TABLE dim_customer (
    customer_sk NUMBER GENERATED ALWAYS AS IDENTITY,
    customer_id VARCHAR2(50),
    customer_name VARCHAR2(200),
    email VARCHAR2(200),
    phone VARCHAR2(20),
    city VARCHAR2(100),
    state VARCHAR2(50),
    country VARCHAR2(100),
    customer_type VARCHAR2(50),
    first_order_date DATE,
    last_order_date DATE,
    total_lifetime_value NUMBER(15,2),
    order_count NUMBER,
    active_flag VARCHAR2(1),
    source_system VARCHAR2(50),
    effective_date DATE DEFAULT TRUNC(SYSDATE),
    end_date DATE DEFAULT TO_DATE('9999-12-31','YYYY-MM-DD'),
    is_current VARCHAR2(1) DEFAULT 'Y',
    created_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    PRIMARY KEY (customer_sk)
) COMPRESS;

-- Dimension: Product
CREATE TABLE dim_product (
    product_sk NUMBER GENERATED ALWAYS AS IDENTITY,
    product_id VARCHAR2(50),
    product_name VARCHAR2(300),
    category VARCHAR2(100),
    subcategory VARCHAR2(100),
    unit_cost NUMBER(12,2),
    unit_price NUMBER(12,2),
    margin_percent NUMBER(5,2),
    supplier_id VARCHAR2(50),
    is_discontinued VARCHAR2(1),
    effective_date DATE DEFAULT TRUNC(SYSDATE),
    end_date DATE DEFAULT TO_DATE('9999-12-31','YYYY-MM-DD'),
    is_current VARCHAR2(1) DEFAULT 'Y',
    created_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    PRIMARY KEY (product_sk)
) COMPRESS;

-- Fact Table: Sales
CREATE TABLE fact_sales (
    sales_id NUMBER GENERATED ALWAYS AS IDENTITY,
    order_id VARCHAR2(50),
    customer_sk NUMBER,
    product_sk NUMBER,
    date_sk NUMBER,
    order_quantity NUMBER(10,0),
    unit_price NUMBER(12,2),
    discount_percent NUMBER(5,2),
    discount_amount NUMBER(12,2),
    subtotal_amount NUMBER(12,2),
    tax_amount NUMBER(12,2),
    total_amount NUMBER(12,2),
    cost_amount NUMBER(12,2),
    profit_amount NUMBER(12,2),
    profit_percent NUMBER(5,2),
    order_status VARCHAR2(50),
    payment_method VARCHAR2(50),
    created_date TIMESTAMP DEFAULT SYSTIMESTAMP,
    load_date DATE DEFAULT TRUNC(SYSDATE),
    PRIMARY KEY (sales_id),
    FOREIGN KEY (customer_sk) REFERENCES dim_customer(customer_sk),
    FOREIGN KEY (product_sk) REFERENCES dim_product(product_sk),
    FOREIGN KEY (date_sk) REFERENCES dim_date(date_id)
) COMPRESS PARTITION BY RANGE (load_date) (
    PARTITION part_2023 VALUES LESS THAN (TO_DATE('2024-01-01','YYYY-MM-DD')),
    PARTITION part_2024 VALUES LESS THAN (TO_DATE('2025-01-01','YYYY-MM-DD')),
    PARTITION part_future VALUES LESS THAN (MAXVALUE)
);

-- Fact Indexes
CREATE INDEX idx_fact_customer ON fact_sales(customer_sk);
CREATE INDEX idx_fact_product ON fact_sales(product_sk);
CREATE INDEX idx_fact_date ON fact_sales(date_sk);
CREATE INDEX idx_fact_order ON fact_sales(order_id);

-- ============================================================================
-- PART 5: AGGREGATE TABLES (for performance)
-- ============================================================================

-- Daily Sales Summary
CREATE TABLE agg_daily_sales (
    agg_date DATE,
    total_orders NUMBER,
    total_quantity NUMBER,
    total_revenue NUMBER(15,2),
    total_cost NUMBER(15,2),
    total_profit NUMBER(15,2),
    average_order_value NUMBER(12,2),
    primary_key (agg_date)
) COMPRESS;

-- Customer Metrics
CREATE TABLE agg_customer_metrics (
    customer_sk NUMBER,
    metric_date DATE,
    daily_revenue NUMBER(15,2),
    daily_orders NUMBER,
    month_to_date_revenue NUMBER(15,2),
    month_to_date_orders NUMBER,
    PRIMARY KEY (customer_sk, metric_date),
    FOREIGN KEY (customer_sk) REFERENCES dim_customer(customer_sk)
) COMPRESS;

-- Product Performance
CREATE TABLE agg_product_performance (
    product_sk NUMBER,
    metric_date DATE,
    units_sold NUMBER,
    total_revenue NUMBER(15,2),
    total_profit NUMBER(15,2),
    profit_margin NUMBER(5,2),
    PRIMARY KEY (product_sk, metric_date),
    FOREIGN KEY (product_sk) REFERENCES dim_product(product_sk)
) COMPRESS;

-- ============================================================================
-- PART 6: GRANT PERMISSIONS (For security)
-- ============================================================================

GRANT SELECT ON error_log TO role_bi_analyst;
GRANT SELECT ON audit_log TO role_bi_analyst;
GRANT SELECT ON run_statistics TO role_bi_analyst;
GRANT SELECT ON fact_sales TO role_bi_analyst;
GRANT SELECT ON dim_customer TO role_bi_analyst;
GRANT SELECT ON dim_product TO role_bi_analyst;
GRANT SELECT ON dim_date TO role_bi_analyst;

GRANT INSERT, UPDATE, DELETE ON fact_sales TO role_etl_admin;
GRANT INSERT, UPDATE, DELETE ON dim_customer TO role_etl_admin;
GRANT INSERT, UPDATE, DELETE ON dim_product TO role_etl_admin;

-- ============================================================================
-- PART 7: COLLECT STATISTICS (for optimizer)
-- ============================================================================

BEGIN
    DBMS_STATS.GATHER_SCHEMA_STATS(ownname => USER);
END;
/

COMMIT;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Check all tables created
SELECT table_name FROM user_tables 
WHERE table_name LIKE 'STG_%' OR table_name LIKE 'CLEAN_%' 
   OR table_name LIKE 'DIM_%' OR table_name LIKE 'FACT_%'
   OR table_name LIKE 'AGG_%' OR table_name LIKE '%_LOG'
ORDER BY table_name;

-- Check indexes
SELECT index_name, table_name FROM user_indexes 
WHERE table_name LIKE 'STG_%' OR table_name LIKE 'CLEAN_%' OR table_name LIKE 'FACT_%'
ORDER BY table_name, index_name;
