-- 05_CLEANING_PROCEDURES.sql
-- Purpose: Stored procedures for data cleaning and transformation into intermediate layer.

-- This script implements basic cleaning steps for staging-to-intermediate transformation.

-- NOTE:
-- - Assumes target intermediate tables exist:
--   - int_customers
--   - int_products
--   - int_orders
-- - If your schema uses different names, update table names accordingly.

-- ============================================================================
-- CLEAN/LOAD CUSTOMERS
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_cleanse_customers (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_truncate_first IN VARCHAR2 DEFAULT 'Y'
) IS
    v_batch_id NUMBER;
    v_records_loaded NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;

    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;

    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE int_customers';
    END IF;

    INSERT INTO int_customers (
        int_customer_id,
        customer_name,
        email,
        phone,
        address,
        city,
        state,
        zip_code,
        country,
        customer_type,
        source_system,
        source_id,
        batch_id
    )
    SELECT
        stg.stg_customer_id,
        -- Normalize name
        INITCAP(TRIM(stg.customer_name)),
        -- Normalize email
        LOWER(TRIM(stg.email)),
        TRIM(stg.phone),
        TRIM(stg.address),
        TRIM(stg.city),
        TRIM(stg.state),
        TRIM(stg.zip_code),
        TRIM(stg.country),
        TRIM(stg.customer_type),
        stg.source_system,
        stg.source_id,
        stg.batch_id
    FROM stg_customers stg
    WHERE stg.batch_id = v_batch_id
    -- Basic quality filters
    AND stg.customer_name IS NOT NULL
    AND stg.source_id IS NOT NULL;

    v_records_loaded := SQL%ROWCOUNT;
    v_execution_end := SYSTIMESTAMP;

    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_cleanse_customers', 'INSERT', 'INT_CUSTOMERS', v_records_loaded,
        v_execution_start, v_execution_end, 'SUCCESS'
    );

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_cleanse_customers', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_cleanse_customers;
/

-- ============================================================================
-- CLEAN/LOAD PRODUCTS
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_cleanse_products (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_truncate_first IN VARCHAR2 DEFAULT 'Y'
) IS
    v_batch_id NUMBER;
    v_records_loaded NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;

    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;

    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE int_products';
    END IF;

    INSERT INTO int_products (
        int_product_id,
        product_name,
        category,
        subcategory,
        unit_cost,
        unit_price,
        supplier_id,
        is_discontinued,
        source_system,
        source_id,
        batch_id
    )
    SELECT
        stg.stg_product_id,
        TRIM(stg.product_name),
        TRIM(stg.category),
        TRIM(stg.subcategory),
        NVL(stg.unit_cost, 0),
        NVL(stg.unit_price, 0),
        TRIM(stg.supplier_id),
        stg.is_discontinued,
        stg.source_system,
        stg.source_id,
        stg.batch_id
    FROM stg_products stg
    WHERE stg.batch_id = v_batch_id
    AND stg.product_id IS NOT NULL;

    v_records_loaded := SQL%ROWCOUNT;
    v_execution_end := SYSTIMESTAMP;

    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_cleanse_products', 'INSERT', 'INT_PRODUCTS', v_records_loaded,
        v_execution_start, v_execution_end, 'SUCCESS'
    );

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_cleanse_products', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_cleanse_products;
/

-- ============================================================================
-- CLEAN/LOAD ORDERS
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_cleanse_orders (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_truncate_first IN VARCHAR2 DEFAULT 'Y'
) IS
    v_batch_id NUMBER;
    v_records_loaded NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;

    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;

    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE int_orders';
    END IF;

    -- Basic cleaning:
    -- - normalize status
    -- - ensure monetary fields are not null
    -- - de-duplicate by order_id (keep latest row by stg_order_id)
    INSERT INTO int_orders (
        int_order_id,
        order_id,
        customer_id,
        product_id,
        order_date,
        order_quantity,
        unit_price,
        total_amount,
        discount_percent,
        tax_amount,
        status,
        payment_method,
        source_system,
        source_id,
        batch_id
    )
    SELECT
        x.stg_order_id,
        x.order_id,
        x.customer_id,
        x.product_id,
        x.order_date,
        NVL(x.order_quantity, 0),
        NVL(x.unit_price, 0),
        NVL(x.total_amount, 0),
        NVL(x.discount_percent, 0),
        NVL(x.tax_amount, 0),
        CASE
            WHEN UPPER(TRIM(x.status)) IN ('COMPLETE','COMPLETED','SHIPPED') THEN 'COMPLETED'
            WHEN UPPER(TRIM(x.status)) IN ('CANCELLED','CANCELED') THEN 'CANCELLED'
            WHEN UPPER(TRIM(x.status)) IS NULL OR TRIM(x.status) = '' THEN 'UNKNOWN'
            ELSE TRIM(x.status)
        END,
        TRIM(x.payment_method),
        x.source_system,
        x.source_id,
        x.batch_id
    FROM (
        SELECT
            stg.*,
            ROW_NUMBER() OVER (PARTITION BY stg.order_id ORDER BY stg.stg_order_id DESC) rn
        FROM stg_orders stg
        WHERE stg.batch_id = v_batch_id
    ) x
    WHERE x.rn = 1
    AND x.order_id IS NOT NULL;

    v_records_loaded := SQL%ROWCOUNT;
    v_execution_end := SYSTIMESTAMP;

    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_cleanse_orders', 'INSERT', 'INT_ORDERS', v_records_loaded,
        v_execution_start, v_execution_end, 'SUCCESS'
    );

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_cleanse_orders', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_cleanse_orders;
/

-- ============================================================================
-- MASTER CLEANING PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_cleanse_all (
    p_batch_id IN NUMBER DEFAULT NULL
) IS
    v_batch_id NUMBER;
    v_customers_loaded NUMBER := 0;
    v_products_loaded NUMBER := 0;
    v_orders_loaded NUMBER := 0;
    v_execution_start TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;

    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;

    BEGIN
        sp_cleanse_customers(v_batch_id, 'Y');
        SELECT COUNT(*) INTO v_customers_loaded FROM int_customers WHERE batch_id = v_batch_id;
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_cleanse_all', TO_CHAR(SQLCODE), 'Failed to cleanse customers: ' || SQLERRM);
            COMMIT;
            RAISE;
    END;

    BEGIN
        sp_cleanse_products(v_batch_id, 'Y');
        SELECT COUNT(*) INTO v_products_loaded FROM int_products WHERE batch_id = v_batch_id;
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_cleanse_all', TO_CHAR(SQLCODE), 'Failed to cleanse products: ' || SQLERRM);
            COMMIT;
            RAISE;
    END;

    BEGIN
        sp_cleanse_orders(v_batch_id, 'Y');
        SELECT COUNT(*) INTO v_orders_loaded FROM int_orders WHERE batch_id = v_batch_id;
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_cleanse_all', TO_CHAR(SQLCODE), 'Failed to cleanse orders: ' || SQLERRM);
            COMMIT;
            RAISE;
    END;

    INSERT INTO run_statistics (
        int_customers_loaded,
        int_orders_loaded,
        int_products_loaded,
        run_type,
        pipeline_status
    ) VALUES (
        v_customers_loaded,
        v_orders_loaded,
        v_products_loaded,
        'CLEANING',
        'SUCCESS'
    );

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_cleanse_all', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_cleanse_all;
/


