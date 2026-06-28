-- Raw data loading from source systems into staging layer
-- LOAD STAGING CUSTOMERS

CREATE OR REPLACE PROCEDURE sp_load_staging_customers (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_source_system IN VARCHAR2 DEFAULT 'ALL',
    p_truncate_first IN VARCHAR2 DEFAULT 'Y'
) IS
    v_batch_id NUMBER;
    v_records_loaded NUMBER := 0;
    v_records_failed NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    
    -- Generate batch ID if not provided
    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('Starting sp_load_staging_customers - Batch: ' || v_batch_id);
    
    -- STEP 1: Truncate staging table if requested
    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE stg_customers';
        DBMS_OUTPUT.PUT_LINE('Truncated STG_CUSTOMERS table');
    END IF;
    
    -- STEP 2: Load from CRM_SALESFORCE (example source 1)
    IF p_source_system IN ('ALL', 'CRM_SALESFORCE') THEN
        BEGIN
            INSERT INTO stg_customers (
                stg_customer_id, customer_name, email, phone, address, city, state, 
                zip_code, country, customer_type, source_system, source_id, batch_id
            )
            SELECT 
                ROWNUM,
                TRIM(name),
                LOWER(TRIM(email)),
                TRIM(phone),
                TRIM(address),
                TRIM(city),
                TRIM(state),
                TRIM(postal_code),
                TRIM(country),
                TRIM(customer_segment),
                'CRM_SALESFORCE',
                account_id,
                v_batch_id
            FROM ext_salesforce_accounts -- External table or DB link
            WHERE is_active = 1
            AND created_date >= TRUNC(SYSDATE) - 30; -- Last 30 days
            
            v_records_loaded := SQL%ROWCOUNT;
            DBMS_OUTPUT.PUT_LINE('Loaded ' || v_records_loaded || ' records from CRM_SALESFORCE');
        EXCEPTION
            WHEN OTHERS THEN
                v_records_failed := 1;
                INSERT INTO error_log (procedure_name, error_code, error_message, error_context)
                VALUES ('sp_load_staging_customers', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM), 'Loading from CRM_SALESFORCE');
                DBMS_OUTPUT.PUT_LINE('ERROR loading from CRM_SALESFORCE: ' || SQLERRM);
        END;
    END IF;
    
    -- STEP 3: Load from ERP_SAP (example source 2)
    IF p_source_system IN ('ALL', 'ERP_SAP') THEN
        BEGIN
            INSERT INTO stg_customers (
                stg_customer_id, customer_name, email, phone, address, city, state, 
                zip_code, country, customer_type, source_system, source_id, batch_id
            )
            SELECT 
                ROWNUM + 100000,
                TRIM(kunnm),
                LOWER(TRIM(smtp_addr)),
                TRIM(telf1),
                TRIM(stras),
                TRIM(ort01),
                TRIM(land1),
                TRIM(pstlz),
                TRIM(land1),
                CASE 
                    WHEN ktokd IN ('0001', '0002') THEN 'RETAIL'
                    WHEN ktokd = '0003' THEN 'WHOLESALE'
                    ELSE 'ENTERPRISE'
                END,
                'ERP_SAP',
                kunnr,
                v_batch_id
            FROM ext_sap_customers -- External table or DB link
            WHERE loevm = '';
            
            v_records_loaded := v_records_loaded + SQL%ROWCOUNT;
            DBMS_OUTPUT.PUT_LINE('Loaded ' || SQL%ROWCOUNT || ' records from ERP_SAP');
        EXCEPTION
            WHEN OTHERS THEN
                v_records_failed := v_records_failed + 1;
                INSERT INTO error_log (procedure_name, error_code, error_message, error_context)
                VALUES ('sp_load_staging_customers', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM), 'Loading from ERP_SAP');
                DBMS_OUTPUT.PUT_LINE('ERROR loading from ERP_SAP: ' || SQLERRM);
        END;
    END IF;
    
    -- STEP 4: Commit changes
    COMMIT;
    v_execution_end := SYSTIMESTAMP;
    
    -- STEP 5: Log audit trail
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected, 
        execution_start, execution_end, status
    ) VALUES (
        'sp_load_staging_customers', 'INSERT', 'STG_CUSTOMERS', v_records_loaded,
        v_execution_start, v_execution_end,
        CASE WHEN v_records_failed = 0 THEN 'SUCCESS' ELSE 'PARTIAL' END
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('sp_load_staging_customers completed. Records: ' || v_records_loaded);
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_load_staging_customers', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_load_staging_customers;
/

-- ============================================================================
-- LOAD STAGING ORDERS
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_load_staging_orders (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_days_back IN NUMBER DEFAULT 30,
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
    
    DBMS_OUTPUT.PUT_LINE('Starting sp_load_staging_orders - Batch: ' || v_batch_id);
    
    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE stg_orders';
    END IF;
    
    -- Bulk insert from order source system (typically OLTP)
    INSERT INTO stg_orders (
        stg_order_id, order_id, customer_id, product_id, order_date,
        order_quantity, unit_price, total_amount, discount_percent, tax_amount,
        status, payment_method, source_system, source_id, batch_id
    )
    SELECT 
        ROWNUM,
        o.order_number,
        o.cust_id,
        oi.sku,
        TRUNC(o.order_date),
        oi.quantity,
        oi.unit_price,
        oi.quantity * oi.unit_price * (1 - NVL(o.discount_pct, 0) / 100),
        NVL(o.discount_pct, 0),
        ROUND(oi.quantity * oi.unit_price * 0.08, 2), -- 8% tax
        o.order_status,
        o.payment_type,
        'OLTP_ORDERS',
        o.order_number,
        v_batch_id
    FROM ext_orders o
    INNER JOIN ext_order_items oi ON o.order_id = oi.order_id
    WHERE o.order_date >= TRUNC(SYSDATE) - p_days_back
    AND o.order_status NOT IN ('DELETED', 'DRAFT');
    
    v_records_loaded := SQL%ROWCOUNT;
    COMMIT;
    v_execution_end := SYSTIMESTAMP;
    
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected, 
        execution_start, execution_end, status
    ) VALUES (
        'sp_load_staging_orders', 'INSERT', 'STG_ORDERS', v_records_loaded,
        v_execution_start, v_execution_end, 'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('sp_load_staging_orders completed. Records: ' || v_records_loaded);
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_load_staging_orders', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_load_staging_orders;
/

-- ============================================================================
-- LOAD STAGING PRODUCTS
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_load_staging_products (
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
    
    DBMS_OUTPUT.PUT_LINE('Starting sp_load_staging_products - Batch: ' || v_batch_id);
    
    IF p_truncate_first = 'Y' THEN
        EXECUTE IMMEDIATE 'TRUNCATE TABLE stg_products';
    END IF;
    
    -- Load products from master data source
    INSERT INTO stg_products (
        stg_product_id, product_id, product_name, category, subcategory,
        unit_cost, unit_price, supplier_id, is_discontinued, 
        source_system, source_id, batch_id
    )
    SELECT 
        ROWNUM,
        p.product_code,
        TRIM(p.product_description),
        TRIM(p.product_category),
        TRIM(p.product_subcategory),
        NVL(p.standard_cost, 0),
        NVL(p.list_price, 0),
        p.supplier_code,
        CASE WHEN p.discontinued_flag = 'Y' THEN 'Y' ELSE 'N' END,
        'MASTER_PRODUCT_DB',
        p.product_id,
        v_batch_id
    FROM ext_products p
    WHERE p.active_flag = 'Y'
    OR p.discontinued_flag = 'N'; -- Include active products
    
    v_records_loaded := SQL%ROWCOUNT;
    COMMIT;
    v_execution_end := SYSTIMESTAMP;
    
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected, 
        execution_start, execution_end, status
    ) VALUES (
        'sp_load_staging_products', 'INSERT', 'STG_PRODUCTS', v_records_loaded,
        v_execution_start, v_execution_end, 'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('sp_load_staging_products completed. Records: ' || v_records_loaded);
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_load_staging_products', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
        RAISE;
END sp_load_staging_products;
/

-- ============================================================================
-- MASTER STAGING PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_load_all_staging (
    p_batch_id IN NUMBER DEFAULT NULL,
    p_parallel_degree IN NUMBER DEFAULT 2
) IS
    v_batch_id NUMBER;
    v_execution_start TIMESTAMP;
    v_customers_loaded NUMBER := 0;
    v_orders_loaded NUMBER := 0;
    v_products_loaded NUMBER := 0;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    
    IF p_batch_id IS NULL THEN
        v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    ELSE
        v_batch_id := p_batch_id;
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('=== STAGING LAYER LOAD START ===');
    DBMS_OUTPUT.PUT_LINE('Batch ID: ' || v_batch_id);
    DBMS_OUTPUT.PUT_LINE('Timestamp: ' || v_execution_start);
    
    -- Load customers
    BEGIN
        sp_load_staging_customers(v_batch_id, 'ALL', 'Y');
        SELECT COUNT(*) INTO v_customers_loaded FROM stg_customers WHERE batch_id = v_batch_id;
        DBMS_OUTPUT.PUT_LINE('✓ Customers loaded: ' || v_customers_loaded);
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_load_all_staging', TO_CHAR(SQLCODE), 'Failed to load customers: ' || SQLERRM);
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('✗ ERROR loading customers');
    END;
    
    -- Load products
    BEGIN
        sp_load_staging_products(v_batch_id, 'Y');
        SELECT COUNT(*) INTO v_products_loaded FROM stg_products WHERE batch_id = v_batch_id;
        DBMS_OUTPUT.PUT_LINE('✓ Products loaded: ' || v_products_loaded);
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_load_all_staging', TO_CHAR(SQLCODE), 'Failed to load products: ' || SQLERRM);
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('✗ ERROR loading products');
    END;
    
    -- Load orders (depends on products being loaded first)
    BEGIN
        sp_load_staging_orders(v_batch_id, 30, 'Y');
        SELECT COUNT(*) INTO v_orders_loaded FROM stg_orders WHERE batch_id = v_batch_id;
        DBMS_OUTPUT.PUT_LINE('✓ Orders loaded: ' || v_orders_loaded);
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('sp_load_all_staging', TO_CHAR(SQLCODE), 'Failed to load orders: ' || SQLERRM);
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('✗ ERROR loading orders');
    END;
    
    -- Update run statistics
    INSERT INTO run_statistics (
        stg_customers_loaded,
        stg_orders_loaded,
        stg_products_loaded,
        run_type,
        pipeline_status
    ) VALUES (
        v_customers_loaded,
        v_orders_loaded,
        v_products_loaded,
        'STAGING',
        'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('=== STAGING LAYER LOAD COMPLETE ===');
    DBMS_OUTPUT.PUT_LINE('Total Customers: ' || v_customers_loaded);
    DBMS_OUTPUT.PUT_LINE('Total Products: ' || v_products_loaded);
    DBMS_OUTPUT.PUT_LINE('Total Orders: ' || v_orders_loaded);
    DBMS_OUTPUT.PUT_LINE('Duration: ' || 
        ROUND((SYSTIMESTAMP - v_execution_start) * 24 * 60, 2) || ' minutes');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_load_all_staging', TO_CHAR(SQLCODE), 'Master staging failed: ' || SQLERRM);
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('!!! CRITICAL ERROR in staging layer !!!');
        RAISE;
END sp_load_all_staging;
/

-- ============================================================================
-- VALIDATE STAGING DATA QUALITY
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_validate_all_staging IS
    v_total_customers NUMBER;
    v_valid_customers NUMBER;
    v_total_orders NUMBER;
    v_total_products NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== STAGING DATA QUALITY VALIDATION ===');
    
    -- Validate customers
    SELECT COUNT(*) INTO v_total_customers FROM stg_customers;
    SELECT COUNT(*) INTO v_valid_customers 
    FROM stg_customers 
    WHERE customer_name IS NOT NULL 
    AND source_id IS NOT NULL;
    
    DBMS_OUTPUT.PUT_LINE('Customers: ' || v_valid_customers || '/' || v_total_customers || 
        ' valid (' || ROUND((v_valid_customers/NULLIF(v_total_customers,0))*100,1) || '%)');
    
    -- Validate orders
    SELECT COUNT(*) INTO v_total_orders FROM stg_orders;
    DBMS_OUTPUT.PUT_LINE('Orders: ' || v_total_orders || ' records loaded');
    
    -- Validate products
    SELECT COUNT(*) INTO v_total_products FROM stg_products;
    DBMS_OUTPUT.PUT_LINE('Products: ' || v_total_products || ' records loaded');
    
    IF (v_valid_customers / NULLIF(v_total_customers, 0)) < 0.95 THEN
        DBMS_OUTPUT.PUT_LINE('⚠ WARNING: Less than 95% valid customers');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('=== VALIDATION COMPLETE ===');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in validation: ' || SQLERRM);
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_validate_all_staging', TO_CHAR(SQLCODE), TO_CHAR(SQLERRM));
        COMMIT;
END sp_validate_all_staging;
/

COMMIT;
