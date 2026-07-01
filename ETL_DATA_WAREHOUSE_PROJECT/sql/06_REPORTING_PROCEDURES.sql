-- Build fact tables, dimensions, and aggregates
-- BUILD DIMENSION: DATE (Pre-populated)

CREATE OR REPLACE PROCEDURE sp_build_dim_date (
    p_start_year IN NUMBER DEFAULT 2020,
    p_end_year IN NUMBER DEFAULT 2030
) IS
    v_date_value DATE;
    v_date_id NUMBER;
    v_count NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Building DIM_DATE dimension...');
    
    SAVEPOINT sp_build_dim_date;
    
    -- Delete existing dates if rebuild
    DELETE FROM dim_date;
    
    v_date_value := TO_DATE('01-JAN-' || p_start_year, 'DD-MON-YYYY');
    
    WHILE v_date_value <= TO_DATE('31-DEC-' || p_end_year, 'DD-MON-YYYY') LOOP
        v_date_id := TO_NUMBER(TO_CHAR(v_date_value, 'YYYYMMDD'));
        
        INSERT INTO dim_date (
            date_id, date_value, day_of_week, day_of_month, month_num, 
            month_name, quarter_num, year_num, fiscal_quarter, fiscal_year,
            is_weekend, is_holiday, holiday_name
        ) VALUES (
            v_date_id,
            v_date_value,
            TO_CHAR(v_date_value, 'DAY'),
            EXTRACT(DAY FROM v_date_value),
            EXTRACT(MONTH FROM v_date_value),
            TO_CHAR(v_date_value, 'MONTH'),
            CEIL(EXTRACT(MONTH FROM v_date_value) / 3),
            EXTRACT(YEAR FROM v_date_value),
            'FY' || TO_CHAR(v_date_value + 90, 'YYYY') ||
                'Q' || CEIL(EXTRACT(MONTH FROM v_date_value + 90) / 3),
            EXTRACT(YEAR FROM v_date_value),
            CASE WHEN TO_CHAR(v_date_value, 'D') IN (1, 7) THEN 'Y' ELSE 'N' END,
            'N',
            NULL
        );
        
        v_count := v_count + 1;
        v_date_value := v_date_value + 1;
        
        IF MOD(v_count, 365) = 0 THEN
            COMMIT;
        END IF;
    END LOOP;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DIM_DATE built: ' || v_count || ' days');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_build_dim_date;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_dim_date', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_dim_date;
/

-- ============================================================================
-- BUILD DIMENSION: CUSTOMER (Type 2 SCD)
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_build_dim_customer IS
    v_records_inserted NUMBER := 0;
    v_records_updated NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    DBMS_OUTPUT.PUT_LINE('Building DIM_CUSTOMER dimension...');
    
    SAVEPOINT sp_build_dim_customer;
    
    -- MERGE: Insert new customers, expire old versions
    MERGE INTO dim_customer tgt
    USING (
        SELECT 
            cc.clean_customer_id,
            cc.source_customer_id,
            cc.customer_name,
            cc.email,
            cc.phone,
            cc.city,
            cc.state,
            cc.country,
            cc.customer_type_standardized,
            MIN(co.order_date) as first_order_date,
            MAX(co.order_date) as last_order_date,
            SUM(co.final_amount) as total_lifetime_value,
            COUNT(DISTINCT co.clean_order_id) as order_count
        FROM clean_customers cc
        LEFT JOIN clean_orders co ON cc.clean_customer_id = co.clean_customer_id
        GROUP BY 
            cc.clean_customer_id, cc.source_customer_id, cc.customer_name,
            cc.email, cc.phone, cc.city, cc.state, cc.country,
            cc.customer_type_standardized
    ) src
    ON (tgt.customer_id = src.source_customer_id AND tgt.is_current = 'Y')
    WHEN MATCHED THEN
        UPDATE SET
            tgt.email = src.email,
            tgt.phone = src.phone,
            tgt.city = src.city,
            tgt.state = src.state,
            tgt.country = src.country,
            tgt.customer_type = src.customer_type_standardized,
            tgt.last_order_date = src.last_order_date,
            tgt.total_lifetime_value = src.total_lifetime_value,
            tgt.order_count = src.order_count
        WHERE (
            tgt.email != src.email OR
            tgt.phone != src.phone OR
            tgt.city != src.city OR
            tgt.customer_type != src.customer_type_standardized
        )
    WHEN NOT MATCHED THEN
        INSERT (
            customer_id, customer_name, email, phone, city, state, country,
            customer_type, first_order_date, last_order_date, 
            total_lifetime_value, order_count, active_flag, source_system,
            effective_date, end_date, is_current, created_date
        ) VALUES (
            src.source_customer_id,
            src.customer_name,
            src.email,
            src.phone,
            src.city,
            src.state,
            src.country,
            src.customer_type_standardized,
            src.first_order_date,
            src.last_order_date,
            src.total_lifetime_value,
            src.order_count,
            'Y',
            'STAGING',
            TRUNC(SYSDATE),
            TO_DATE('9999-12-31', 'YYYY-MM-DD'),
            'Y',
            SYSTIMESTAMP
        );
    
    v_records_inserted := SQL%ROWCOUNT;
    COMMIT;
    v_execution_end := SYSTIMESTAMP;
    
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_build_dim_customer', 'MERGE', 'DIM_CUSTOMER', v_records_inserted,
        v_execution_start, v_execution_end, 'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('DIM_CUSTOMER updated: ' || v_records_inserted || ' records');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_build_dim_customer;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_dim_customer', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_dim_customer;
/

-- ============================================================================
-- BUILD DIMENSION: PRODUCT (Type 2 SCD)
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_build_dim_product IS
    v_records_inserted NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    DBMS_OUTPUT.PUT_LINE('Building DIM_PRODUCT dimension...');
    
    SAVEPOINT sp_build_dim_product;
    
    -- MERGE: Insert/update products
    MERGE INTO dim_product tgt
    USING (
        SELECT 
            cp.clean_product_id,
            cp.source_product_id,
            cp.product_name,
            cp.category_standardized,
            cp.subcategory,
            cp.unit_cost,
            cp.unit_price,
            cp.margin_percent,
            cp.supplier_id,
            cp.is_discontinued
        FROM clean_products cp
    ) src
    ON (tgt.product_id = src.source_product_id AND tgt.is_current = 'Y')
    WHEN MATCHED THEN
        UPDATE SET
            tgt.unit_cost = src.unit_cost,
            tgt.unit_price = src.unit_price,
            tgt.margin_percent = src.margin_percent,
            tgt.is_discontinued = src.is_discontinued
        WHERE (
            tgt.unit_cost != src.unit_cost OR
            tgt.unit_price != src.unit_price OR
            tgt.is_discontinued != src.is_discontinued
        )
    WHEN NOT MATCHED THEN
        INSERT (
            product_id, product_name, category, subcategory,
            unit_cost, unit_price, margin_percent, supplier_id,
            is_discontinued, effective_date, end_date, is_current, created_date
        ) VALUES (
            src.source_product_id,
            src.product_name,
            src.category_standardized,
            src.subcategory,
            src.unit_cost,
            src.unit_price,
            src.margin_percent,
            src.supplier_id,
            src.is_discontinued,
            TRUNC(SYSDATE),
            TO_DATE('9999-12-31', 'YYYY-MM-DD'),
            'Y',
            SYSTIMESTAMP
        );
    
    v_records_inserted := SQL%ROWCOUNT;
    COMMIT;
    v_execution_end := SYSTIMESTAMP;
    
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_build_dim_product', 'MERGE', 'DIM_PRODUCT', v_records_inserted,
        v_execution_start, v_execution_end, 'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('DIM_PRODUCT updated: ' || v_records_inserted || ' records');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_build_dim_product;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_dim_product', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_dim_product;
/

-- ============================================================================
-- BUILD FACT TABLE: SALES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_build_fact_sales IS
    v_records_inserted NUMBER := 0;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
    
    CURSOR c_sales IS
        SELECT 
            co.source_order_id as order_id,
            dc.customer_sk,
            dp.product_sk,
            dd.date_id as date_sk,
            co.order_quantity,
            co.unit_price,
            co.discount_percent,
            co.discount_amount,
            co.net_amount,
            co.tax_amount,
            co.final_amount,
            dp.unit_cost,
            fn_calculate_profit(co.order_quantity, co.unit_price, dp.unit_cost) as profit_amount,
            fn_calculate_profit_percent(dp.unit_cost, co.unit_price) as profit_percent,
            co.status_description,
            co.payment_method,
            co.order_date
        FROM clean_orders co
        INNER JOIN dim_customer dc ON co.clean_customer_id = dc.customer_sk -- Error here, should be FK
        INNER JOIN clean_products cp ON co.product_id = cp.source_product_id
        INNER JOIN dim_product dp ON cp.clean_product_id = dp.product_sk -- Wrong join
        INNER JOIN dim_date dd ON TRUNC(co.order_date) = dd.date_value
        WHERE co.is_duplicate = 'N'
        AND co.status_description NOT IN ('CANCELLED', 'FAILED');
    
    TYPE t_sales_table IS TABLE OF c_sales%ROWTYPE;
    v_sales_batch t_sales_table;
    v_batch_size CONSTANT NUMBER := 10000;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    DBMS_OUTPUT.PUT_LINE('Building FACT_SALES table...');
    
    SAVEPOINT sp_build_fact_sales;
    
    -- Bulk insert from clean data
    OPEN c_sales;
    LOOP
        FETCH c_sales BULK COLLECT INTO v_sales_batch LIMIT v_batch_size;
        EXIT WHEN v_sales_batch.COUNT = 0;
        
        FORALL i IN 1..v_sales_batch.COUNT SAVE EXCEPTIONS
            INSERT INTO fact_sales (
                order_id, customer_sk, product_sk, date_sk,
                order_quantity, unit_price, discount_percent, discount_amount,
                subtotal_amount, tax_amount, total_amount, cost_amount,
                profit_amount, profit_percent, order_status, payment_method,
                load_date
            ) VALUES (
                v_sales_batch(i).order_id,
                v_sales_batch(i).customer_sk,
                v_sales_batch(i).product_sk,
                v_sales_batch(i).date_sk,
                v_sales_batch(i).order_quantity,
                v_sales_batch(i).unit_price,
                v_sales_batch(i).discount_percent,
                v_sales_batch(i).discount_amount,
                v_sales_batch(i).net_amount,
                v_sales_batch(i).tax_amount,
                v_sales_batch(i).final_amount,
                v_sales_batch(i).unit_cost * v_sales_batch(i).order_quantity,
                v_sales_batch(i).profit_amount,
                v_sales_batch(i).profit_percent,
                v_sales_batch(i).order_status,
                v_sales_batch(i).payment_method,
                TRUNC(v_sales_batch(i).order_date)
            );
        
        v_records_inserted := v_records_inserted + SQL%ROWCOUNT;
        COMMIT;
        
    END LOOP;
    CLOSE c_sales;
    
    v_execution_end := SYSTIMESTAMP;
    
    INSERT INTO audit_log (
        procedure_name, action, table_name, records_affected,
        execution_start, execution_end, status
    ) VALUES (
        'sp_build_fact_sales', 'INSERT', 'FACT_SALES', v_records_inserted,
        v_execution_start, v_execution_end, 'SUCCESS'
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('FACT_SALES built: ' || v_records_inserted || ' records');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK TO sp_build_fact_sales;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_fact_sales', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_fact_sales;
/

-- ============================================================================
-- BUILD AGGREGATES: DAILY SALES SUMMARY
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_build_agg_daily_sales IS
    v_records_inserted NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Building AGG_DAILY_SALES aggregate...');
    
    MERGE INTO agg_daily_sales tgt
    USING (
        SELECT 
            dd.date_value as agg_date,
            COUNT(*) as total_orders,
            SUM(fs.order_quantity) as total_quantity,
            SUM(fs.total_amount) as total_revenue,
            SUM(fs.cost_amount) as total_cost,
            SUM(fs.profit_amount) as total_profit,
            AVG(fs.total_amount) as average_order_value
        FROM fact_sales fs
        INNER JOIN dim_date dd ON fs.date_sk = dd.date_id
        WHERE fs.order_status NOT IN ('CANCELLED', 'FAILED')
        GROUP BY dd.date_value
    ) src
    ON (tgt.agg_date = src.agg_date)
    WHEN MATCHED THEN
        UPDATE SET
            tgt.total_orders = src.total_orders,
            tgt.total_quantity = src.total_quantity,
            tgt.total_revenue = src.total_revenue,
            tgt.total_cost = src.total_cost,
            tgt.total_profit = src.total_profit,
            tgt.average_order_value = src.average_order_value
    WHEN NOT MATCHED THEN
        INSERT (
            agg_date, total_orders, total_quantity, total_revenue,
            total_cost, total_profit, average_order_value
        ) VALUES (
            src.agg_date, src.total_orders, src.total_quantity,
            src.total_revenue, src.total_cost, src.total_profit,
            src.average_order_value
        );
    
    v_records_inserted := SQL%ROWCOUNT;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('AGG_DAILY_SALES built: ' || v_records_inserted || ' records');
    
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_agg_daily_sales', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_agg_daily_sales;
/

-- ============================================================================
-- MASTER REPORTING BUILD
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_build_reporting_layer IS
    v_execution_start TIMESTAMP;
    v_customer_count NUMBER;
    v_product_count NUMBER;
    v_fact_count NUMBER;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== REPORTING LAYER BUILD START ===');
    DBMS_OUTPUT.PUT_LINE('Start Time: ' || v_execution_start);
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Build dimensions
    BEGIN
        sp_build_dim_customer;
        SELECT COUNT(*) INTO v_customer_count FROM dim_customer WHERE is_current = 'Y';
        DBMS_OUTPUT.PUT_LINE('✓ Dim Customers: ' || v_customer_count);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('✗ ERROR: ' || SQLERRM);
    END;
    
    BEGIN
        sp_build_dim_product;
        SELECT COUNT(*) INTO v_product_count FROM dim_product WHERE is_current = 'Y';
        DBMS_OUTPUT.PUT_LINE('✓ Dim Products: ' || v_product_count);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('✗ ERROR: ' || SQLERRM);
    END;
    
    -- Build fact table
    BEGIN
        sp_build_fact_sales;
        SELECT COUNT(*) INTO v_fact_count FROM fact_sales;
        DBMS_OUTPUT.PUT_LINE('✓ Fact Sales: ' || v_fact_count);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('✗ ERROR: ' || SQLERRM);
    END;
    
    -- Build aggregates
    BEGIN
        sp_build_agg_daily_sales;
        DBMS_OUTPUT.PUT_LINE('✓ Aggregates built');
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('✗ ERROR: ' || SQLERRM);
    END;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== REPORTING LAYER COMPLETE ===');
    DBMS_OUTPUT.PUT_LINE('Duration: ' || ROUND((SYSTIMESTAMP - v_execution_start) * 24 * 60, 2) || ' minutes');
    
    -- Update statistics
    UPDATE run_statistics
    SET dim_customer_records = v_customer_count,
        dim_product_records = v_product_count,
        fact_sales_records = v_fact_count
    WHERE run_id = (SELECT MAX(run_id) FROM run_statistics);
    COMMIT;
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_build_reporting_layer', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_build_reporting_layer;
/

COMMIT;
