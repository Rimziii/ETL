-- Error handling, logging, and alerting infrastructure
-- COMPREHENSIVE ERROR LOG PROCEDURE

CREATE OR REPLACE PROCEDURE sp_log_error (
    p_procedure_name IN VARCHAR2,
    p_error_code IN VARCHAR2,
    p_error_message IN VARCHAR2,
    p_context IN VARCHAR2 DEFAULT NULL,
    p_record_count IN NUMBER DEFAULT NULL
) IS
BEGIN
    INSERT INTO error_log (
        procedure_name,
        error_code,
        error_message,
        error_context,
        record_count,
        status,
        notes
    ) VALUES (
        SUBSTR(p_procedure_name, 1, 100),
        SUBSTR(p_error_code, 1, 20),
        SUBSTR(p_error_message, 1, 1000),
        SUBSTR(p_context, 1, 500),
        p_record_count,
        'PENDING',
        'Auto-logged error - ' || TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS')
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR logging error: ' || SQLERRM);
END sp_log_error;
/

-- ============================================================================
-- ERROR ALERT PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_send_alert (
    p_severity IN VARCHAR2, -- CRITICAL, HIGH, MEDIUM, LOW
    p_subject IN VARCHAR2,
    p_message IN VARCHAR2,
    p_recipients IN VARCHAR2 DEFAULT 'admin@company.com'
) IS
    v_alert_body CLOB;
BEGIN
    -- Log the alert
    INSERT INTO error_log (
        procedure_name,
        error_code,
        error_message,
        status,
        notes
    ) VALUES (
        'ALERT_' || p_severity,
        'ALERT',
        p_subject,
        'ACTIVE',
        p_message
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('╔════════════════════════════════════════╗');
    DBMS_OUTPUT.PUT_LINE('║ ALERT: ' || p_severity || CHR(10));
    DBMS_OUTPUT.PUT_LINE('║ Subject: ' || p_subject);
    DBMS_OUTPUT.PUT_LINE('║ Time: ' || SYSTIMESTAMP);
    DBMS_OUTPUT.PUT_LINE('╚════════════════════════════════════════╝');
    DBMS_OUTPUT.PUT_LINE(p_message);
    
    -- In production, integrate with email/Slack/PagerDuty
    -- UTL_MAIL.SEND() or similar
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR sending alert: ' || SQLERRM);
END sp_send_alert;
/

-- ============================================================================
-- RESOLVE ERROR PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_resolve_error (
    p_error_id IN NUMBER,
    p_resolution_notes IN VARCHAR2
) IS
BEGIN
    UPDATE error_log SET
        status = 'RESOLVED',
        notes = p_resolution_notes,
        error_timestamp = SYSTIMESTAMP
    WHERE error_id = p_error_id;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Error ' || p_error_id || ' marked as RESOLVED');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR resolving error: ' || SQLERRM);
        RAISE;
END sp_resolve_error;
/

-- ============================================================================
-- DATA QUALITY CHECK PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_check_data_quality (
    p_table_name IN VARCHAR2,
    p_threshold_percent IN NUMBER DEFAULT 95
) IS
    v_total_records NUMBER;
    v_quality_records NUMBER;
    v_quality_percent NUMBER(5,2);
    v_status VARCHAR2(20);
BEGIN
    CASE p_table_name
        WHEN 'STG_CUSTOMERS' THEN
            SELECT COUNT(*) INTO v_total_records FROM stg_customers;
            SELECT COUNT(*) INTO v_quality_records FROM stg_customers 
            WHERE customer_name IS NOT NULL AND source_id IS NOT NULL;
            
        WHEN 'STG_ORDERS' THEN
            SELECT COUNT(*) INTO v_total_records FROM stg_orders;
            SELECT COUNT(*) INTO v_quality_records FROM stg_orders 
            WHERE order_id IS NOT NULL AND customer_id IS NOT NULL 
            AND order_quantity > 0 AND unit_price > 0;
            
        WHEN 'STG_PRODUCTS' THEN
            SELECT COUNT(*) INTO v_total_records FROM stg_products;
            SELECT COUNT(*) INTO v_quality_records FROM stg_products 
            WHERE product_name IS NOT NULL AND unit_price > 0;
            
        WHEN 'CLEAN_CUSTOMERS' THEN
            SELECT COUNT(*) INTO v_total_records FROM clean_customers;
            SELECT COUNT(*) INTO v_quality_records FROM clean_customers 
            WHERE data_quality_score >= 70;
            
        WHEN 'FACT_SALES' THEN
            SELECT COUNT(*) INTO v_total_records FROM fact_sales;
            SELECT COUNT(*) INTO v_quality_records FROM fact_sales 
            WHERE customer_sk IS NOT NULL AND product_sk IS NOT NULL 
            AND total_amount > 0;
            
        ELSE
            RAISE_APPLICATION_ERROR(-20001, 'Unknown table: ' || p_table_name);
    END CASE;
    
    IF v_total_records = 0 THEN
        v_quality_percent := 0;
    ELSE
        v_quality_percent := ROUND((v_quality_records / v_total_records) * 100, 2);
    END IF;
    
    IF v_quality_percent >= p_threshold_percent THEN
        v_status := 'PASS';
    ELSE
        v_status := 'FAIL';
        sp_send_alert('HIGH', 
            'Data Quality Check Failed: ' || p_table_name,
            'Quality: ' || v_quality_percent || '% (Expected: ' || p_threshold_percent || '%)'
        );
    END IF;
    
    -- Log the check
    INSERT INTO data_quality_metrics (
        table_name,
        check_name,
        records_checked,
        records_passed,
        pass_percentage,
        status
    ) VALUES (
        p_table_name,
        'COMPLETENESS_CHECK',
        v_total_records,
        v_quality_records,
        v_quality_percent,
        v_status
    );
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('Data Quality Check: ' || p_table_name);
    DBMS_OUTPUT.PUT_LINE('  Total Records: ' || v_total_records);
    DBMS_OUTPUT.PUT_LINE('  Quality Records: ' || v_quality_records);
    DBMS_OUTPUT.PUT_LINE('  Pass Percentage: ' || v_quality_percent || '%');
    DBMS_OUTPUT.PUT_LINE('  Status: ' || v_status);
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in quality check: ' || SQLERRM);
        sp_log_error('sp_check_data_quality', SQLCODE, SQLERRM, p_table_name);
        RAISE;
END sp_check_data_quality;
/

-- ============================================================================
-- RECONCILIATION PROCEDURES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_reconcile_staging_clean IS
    v_staging_count NUMBER;
    v_clean_count NUMBER;
    v_variance NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== STAGING TO CLEAN RECONCILIATION ===');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Customers
    SELECT COUNT(*) INTO v_staging_count FROM stg_customers;
    SELECT COUNT(*) INTO v_clean_count FROM clean_customers;
    v_variance := ABS(v_staging_count - v_clean_count);
    
    DBMS_OUTPUT.PUT_LINE('Customers:');
    DBMS_OUTPUT.PUT_LINE('  Staging: ' || v_staging_count);
    DBMS_OUTPUT.PUT_LINE('  Clean: ' || v_clean_count);
    DBMS_OUTPUT.PUT_LINE('  Variance: ' || v_variance || ' records (' || 
        ROUND((v_variance/NULLIF(v_staging_count,0))*100,2) || '%)');
    
    IF v_variance > (v_staging_count * 0.05) THEN
        sp_send_alert('MEDIUM', 'Customer Reconciliation Variance > 5%', 
            'Check for data quality issues');
    END IF;
    
    -- Orders
    SELECT COUNT(*) INTO v_staging_count FROM stg_orders;
    SELECT COUNT(*) INTO v_clean_count FROM clean_orders WHERE is_duplicate = 'N';
    v_variance := ABS(v_staging_count - v_clean_count);
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Orders:');
    DBMS_OUTPUT.PUT_LINE('  Staging: ' || v_staging_count);
    DBMS_OUTPUT.PUT_LINE('  Clean (non-dup): ' || v_clean_count);
    DBMS_OUTPUT.PUT_LINE('  Variance: ' || v_variance || ' records');
    
    -- Products
    SELECT COUNT(*) INTO v_staging_count FROM stg_products;
    SELECT COUNT(*) INTO v_clean_count FROM clean_products;
    v_variance := ABS(v_staging_count - v_clean_count);
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Products:');
    DBMS_OUTPUT.PUT_LINE('  Staging: ' || v_staging_count);
    DBMS_OUTPUT.PUT_LINE('  Clean: ' || v_clean_count);
    DBMS_OUTPUT.PUT_LINE('  Variance: ' || v_variance);
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== END RECONCILIATION ===');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in reconciliation: ' || SQLERRM);
        sp_log_error('sp_reconcile_staging_clean', SQLCODE, SQLERRM);
        RAISE;
END sp_reconcile_staging_clean;
/

-- ============================================================================
-- RECONCILE CLEAN TO REPORTING
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_reconcile_clean_reporting IS
    v_clean_orders NUMBER;
    v_fact_orders NUMBER;
    v_variance NUMBER;
    v_clean_revenue NUMBER;
    v_fact_revenue NUMBER;
    v_revenue_variance NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== CLEAN TO REPORTING RECONCILIATION ===');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Order count
    SELECT COUNT(*) INTO v_clean_orders FROM clean_orders WHERE is_duplicate = 'N';
    SELECT COUNT(*) INTO v_fact_orders FROM fact_sales;
    v_variance := ABS(v_clean_orders - v_fact_orders);
    
    DBMS_OUTPUT.PUT_LINE('Order Count:');
    DBMS_OUTPUT.PUT_LINE('  Clean: ' || v_clean_orders);
    DBMS_OUTPUT.PUT_LINE('  Fact: ' || v_fact_orders);
    DBMS_OUTPUT.PUT_LINE('  Variance: ' || v_variance);
    
    -- Revenue
    SELECT SUM(final_amount) INTO v_clean_revenue FROM clean_orders WHERE is_duplicate = 'N';
    SELECT SUM(total_amount) INTO v_fact_revenue FROM fact_sales;
    v_revenue_variance := ABS(NVL(v_clean_revenue, 0) - NVL(v_fact_revenue, 0));
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Total Revenue:');
    DBMS_OUTPUT.PUT_LINE('  Clean: $' || NVL(v_clean_revenue, 0));
    DBMS_OUTPUT.PUT_LINE('  Fact: $' || NVL(v_fact_revenue, 0));
    DBMS_OUTPUT.PUT_LINE('  Variance: $' || v_revenue_variance);
    
    IF v_revenue_variance > (NVL(v_clean_revenue, 0) * 0.01) THEN
        sp_send_alert('CRITICAL', 'Revenue Reconciliation Variance > 1%', 
            'Clean: $' || v_clean_revenue || ', Fact: $' || v_fact_revenue
        );
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== END RECONCILIATION ===');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in reconciliation: ' || SQLERRM);
        sp_log_error('sp_reconcile_clean_reporting', SQLCODE, SQLERRM);
        RAISE;
END sp_reconcile_clean_reporting;
/

-- ============================================================================
-- MONITORING & HEALTH CHECK
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_etl_health_check IS
    v_last_run_time TIMESTAMP;
    v_hours_since_run NUMBER;
    v_last_status VARCHAR2(20);
    v_error_count NUMBER;
    v_warning_count NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('╔════════════════════════════════════════════╗');
    DBMS_OUTPUT.PUT_LINE('║           ETL SYSTEM HEALTH CHECK           ║');
    DBMS_OUTPUT.PUT_LINE('╚════════════════════════════════════════════╝');
    DBMS_OUTPUT.PUT_LINE('');
    
    -- Last run info
    SELECT MAX(run_time) INTO v_last_run_time FROM run_statistics;
    
    IF v_last_run_time IS NOT NULL THEN
        v_hours_since_run := ROUND((SYSTIMESTAMP - v_last_run_time) * 24, 1);
        SELECT pipeline_status INTO v_last_status FROM run_statistics 
        WHERE run_time = v_last_run_time AND ROWNUM = 1;
        
        DBMS_OUTPUT.PUT_LINE('Last Run:');
        DBMS_OUTPUT.PUT_LINE('  Time: ' || v_last_run_time);
        DBMS_OUTPUT.PUT_LINE('  Status: ' || v_last_status);
        DBMS_OUTPUT.PUT_LINE('  Hours Ago: ' || v_hours_since_run);
        
        IF v_hours_since_run > 25 THEN
            sp_send_alert('MEDIUM', 'ETL Has Not Run in 25+ Hours', 
                'Last run was ' || v_hours_since_run || ' hours ago');
        END IF;
    ELSE
        DBMS_OUTPUT.PUT_LINE('⚠ NO PREVIOUS RUNS FOUND');
    END IF;
    
    -- Error summary
    SELECT COUNT(*) INTO v_error_count FROM error_log 
    WHERE status = 'PENDING' AND error_timestamp >= SYSDATE - 1;
    
    SELECT COUNT(*) INTO v_warning_count FROM data_quality_metrics
    WHERE status = 'FAIL' AND quality_id IN (
        SELECT MAX(quality_id) FROM data_quality_metrics GROUP BY table_name
    );
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Error Summary (last 24h):');
    DBMS_OUTPUT.PUT_LINE('  Pending Errors: ' || v_error_count);
    DBMS_OUTPUT.PUT_LINE('  Quality Warnings: ' || v_warning_count);
    
    IF v_error_count > 0 OR v_warning_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('⚠ SYSTEM REQUIRES ATTENTION');
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('✓ SYSTEM HEALTHY');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Check Time: ' || SYSTIMESTAMP);
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in health check: ' || SQLERRM);
        RAISE;
END sp_etl_health_check;
/

COMMIT;
