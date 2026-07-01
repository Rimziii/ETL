-- ============================================================================
-- 07_SCHEDULER_JOBS.sql
-- DBMS_SCHEDULER jobs for automated ETL pipeline execution
-- ============================================================================

-- ============================================================================
-- MASTER ETL ORCHESTRATION PROCEDURE
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_master_etl (
    p_run_type IN VARCHAR2 DEFAULT 'FULL',
    p_send_email IN VARCHAR2 DEFAULT 'Y'
) IS
    v_run_id NUMBER;
    v_execution_start TIMESTAMP;
    v_execution_end TIMESTAMP;
    v_total_duration NUMBER(8,2);
    v_batch_id NUMBER;
    v_error_count NUMBER := 0;
    v_total_errors NUMBER;
    v_status VARCHAR2(20);
    v_email_body CLOB;
    
    -- Error handling variables
    v_staging_error NUMBER := 0;
    v_cleaning_error NUMBER := 0;
    v_reporting_error NUMBER := 0;
BEGIN
    v_execution_start := SYSTIMESTAMP;
    v_batch_id := TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'));
    
    -- Create run record
    INSERT INTO run_statistics (
        run_date, run_time, run_type, pipeline_status
    ) VALUES (
        TRUNC(SYSDATE),
        v_execution_start,
        p_run_type,
        'RUNNING'
    ) RETURNING run_id INTO v_run_id;
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('╔════════════════════════════════════════════════════════════╗');
    DBMS_OUTPUT.PUT_LINE('║           DATA WAREHOUSE ETL PIPELINE EXECUTION             ║');
    DBMS_OUTPUT.PUT_LINE('╚════════════════════════════════════════════════════════════╝');
    DBMS_OUTPUT.PUT_LINE('Run ID:       ' || v_run_id);
    DBMS_OUTPUT.PUT_LINE('Batch ID:     ' || v_batch_id);
    DBMS_OUTPUT.PUT_LINE('Run Type:     ' || p_run_type);
    DBMS_OUTPUT.PUT_LINE('Start Time:   ' || v_execution_start);
    DBMS_OUTPUT.PUT_LINE('');
    
    DBMS_OUTPUT.PUT_LINE('PHASE 1: STAGING LAYER');
    DBMS_OUTPUT.PUT_LINE('─────────────────────────────────────');
    BEGIN
        sp_load_all_staging(v_batch_id);
        DBMS_OUTPUT.PUT_LINE('✓ Staging layer completed successfully');
    EXCEPTION
        WHEN OTHERS THEN
            v_staging_error := 1;
            INSERT INTO error_log (procedure_name, error_code, error_message, status)
            VALUES ('sp_master_etl', SQLCODE, 'Staging phase error: ' || SQLERRM, 'PENDING');
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('✗ Staging layer FAILED: ' || SQLERRM);
    END;
    
    IF v_staging_error = 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('PHASE 2: CLEANING LAYER');
        DBMS_OUTPUT.PUT_LINE('─────────────────────────────────────');
        BEGIN
            sp_clean_all_data(v_batch_id);
            DBMS_OUTPUT.PUT_LINE('✓ Cleaning layer completed successfully');
        EXCEPTION
            WHEN OTHERS THEN
                v_cleaning_error := 1;
                INSERT INTO error_log (procedure_name, error_code, error_message, status)
                VALUES ('sp_master_etl', SQLCODE, 'Cleaning phase error: ' || SQLERRM, 'PENDING');
                COMMIT;
                DBMS_OUTPUT.PUT_LINE('✗ Cleaning layer FAILED: ' || SQLERRM);
        END;
    END IF;
    
    IF v_staging_error = 0 AND v_cleaning_error = 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('PHASE 3: REPORTING LAYER');
        DBMS_OUTPUT.PUT_LINE('─────────────────────────────────────');
        BEGIN
            sp_build_reporting_layer;
            DBMS_OUTPUT.PUT_LINE('✓ Reporting layer completed successfully');
        EXCEPTION
            WHEN OTHERS THEN
                v_reporting_error := 1;
                INSERT INTO error_log (procedure_name, error_code, error_message, status)
                VALUES ('sp_master_etl', SQLCODE, 'Reporting phase error: ' || SQLERRM, 'PENDING');
                COMMIT;
                DBMS_OUTPUT.PUT_LINE('✗ Reporting layer FAILED: ' || SQLERRM);
        END;
    END IF;
    
    -- Final status
    v_execution_end := SYSTIMESTAMP;
    v_total_duration := ROUND((v_execution_end - v_execution_start) * 24 * 60, 2);
    
    SELECT COUNT(*) INTO v_total_errors FROM error_log WHERE error_timestamp >= v_execution_start;
    
    IF v_staging_error = 0 AND v_cleaning_error = 0 AND v_reporting_error = 0 THEN
        v_status := 'SUCCESS';
    ELSIF v_staging_error = 0 THEN
        v_status := 'PARTIAL';
    ELSE
        v_status := 'FAILURE';
    END IF;
    
    -- Update run record
    UPDATE run_statistics SET
        pipeline_status = v_status,
        total_errors = v_total_errors,
        total_duration_minutes = v_total_duration,
        next_run_date = TRUNC(SYSDATE + 1) + 2/24 -- Next day at 2 AM
    WHERE run_id = v_run_id;
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('╔════════════════════════════════════════════════════════════╗');
    DBMS_OUTPUT.PUT_LINE('║                    EXECUTION SUMMARY                        ║');
    DBMS_OUTPUT.PUT_LINE('╚════════════════════════════════════════════════════════════╝');
    DBMS_OUTPUT.PUT_LINE('Status:       ' || v_status);
    DBMS_OUTPUT.PUT_LINE('Total Errors: ' || v_total_errors);
    DBMS_OUTPUT.PUT_LINE('Duration:     ' || v_total_duration || ' minutes');
    DBMS_OUTPUT.PUT_LINE('End Time:     ' || v_execution_end);
    DBMS_OUTPUT.PUT_LINE('');
    
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        UPDATE run_statistics SET pipeline_status = 'FAILURE'
        WHERE run_id = v_run_id;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('!!! CRITICAL ERROR IN MASTER ETL !!!');
        DBMS_OUTPUT.PUT_LINE(SQLERRM);
        RAISE;
END sp_master_etl;
/

-- ============================================================================
-- SCHEDULER JOBS SETUP
-- ============================================================================

-- Create program for ETL execution
BEGIN
    DBMS_SCHEDULER.CREATE_PROGRAM (
        program_name => 'etl_pipeline_program',
        program_type => 'STORED_PROCEDURE',
        program_action => 'sp_master_etl',
        number_of_arguments => 2,
        enabled => FALSE,
        comments => 'Master ETL Pipeline Execution'
    );
    
    DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT (
        program_name => 'etl_pipeline_program',
        argument_position => 1,
        argument_name => 'p_run_type',
        argument_type => 'VARCHAR2'
    );
    
    DBMS_SCHEDULER.DEFINE_PROGRAM_ARGUMENT (
        program_name => 'etl_pipeline_program',
        argument_position => 2,
        argument_name => 'p_send_email',
        argument_type => 'VARCHAR2'
    );
    
    DBMS_SCHEDULER.ENABLE(name => 'etl_pipeline_program');
    DBMS_OUTPUT.PUT_LINE('Created ETL Pipeline Program');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27458 THEN
            DBMS_OUTPUT.PUT_LINE('Program already exists');
        ELSE
            RAISE;
        END IF;
END;
/

-- Create nightly ETL job (runs every night at 2 AM)
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name => 'etl_nightly_job',
        program_name => 'etl_pipeline_program',
        schedule_name => 'DAILY_2AM',
        enabled => FALSE,
        comments => 'Nightly ETL pipeline execution'
    );
    
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE (
        job_name => 'etl_nightly_job',
        argument_position => 1,
        argument_value => 'FULL'
    );
    
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE (
        job_name => 'etl_nightly_job',
        argument_position => 2,
        argument_value => 'Y'
    );
    
    DBMS_OUTPUT.PUT_LINE('Created Nightly ETL Job');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27459 THEN
            DBMS_OUTPUT.PUT_LINE('Job already exists');
        ELSE
            RAISE;
        END IF;
END;
/

-- Create hourly incremental job (for high-frequency updates)
BEGIN
    DBMS_SCHEDULER.CREATE_JOB (
        job_name => 'etl_incremental_job',
        program_name => 'etl_pipeline_program',
        schedule_name => 'EVERY_HOUR',
        enabled => FALSE,
        comments => 'Hourly incremental ETL'
    );
    
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE (
        job_name => 'etl_incremental_job',
        argument_position => 1,
        argument_value => 'INCREMENTAL'
    );
    
    DBMS_SCHEDULER.SET_JOB_ARGUMENT_VALUE (
        job_name => 'etl_incremental_job',
        argument_position => 2,
        argument_value => 'N'
    );
    
    DBMS_OUTPUT.PUT_LINE('Created Hourly Incremental Job');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27459 THEN
            DBMS_OUTPUT.PUT_LINE('Job already exists');
        ELSE
            RAISE;
        END IF;
END;
/

-- Create schedules
BEGIN
    DBMS_SCHEDULER.CREATE_SCHEDULE (
        schedule_name => 'DAILY_2AM',
        repeat_interval => 'FREQ=DAILY;BYHOUR=2;BYMINUTE=0;BYSECOND=0',
        comments => 'Runs every day at 2 AM'
    );
    DBMS_OUTPUT.PUT_LINE('Created DAILY_2AM schedule');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27455 THEN
            NULL;
        ELSE
            RAISE;
        END IF;
END;
/

BEGIN
    DBMS_SCHEDULER.CREATE_SCHEDULE (
        schedule_name => 'EVERY_HOUR',
        repeat_interval => 'FREQ=HOURLY;BYMINUTE=0;BYSECOND=0',
        comments => 'Runs every hour'
    );
    DBMS_OUTPUT.PUT_LINE('Created EVERY_HOUR schedule');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE = -27455 THEN
            NULL;
        ELSE
            RAISE;
        END IF;
END;
/

-- ============================================================================
-- ENABLE/DISABLE JOB PROCEDURES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_enable_etl_jobs IS
BEGIN
    DBMS_SCHEDULER.ENABLE(name => 'etl_nightly_job');
    DBMS_OUTPUT.PUT_LINE('Enabled: etl_nightly_job');
    
    DBMS_SCHEDULER.ENABLE(name => 'etl_incremental_job');
    DBMS_OUTPUT.PUT_LINE('Enabled: etl_incremental_job');
    
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR enabling jobs: ' || SQLERRM);
        RAISE;
END sp_enable_etl_jobs;
/

CREATE OR REPLACE PROCEDURE sp_disable_etl_jobs IS
BEGIN
    DBMS_SCHEDULER.DISABLE(name => 'etl_nightly_job');
    DBMS_OUTPUT.PUT_LINE('Disabled: etl_nightly_job');
    
    DBMS_SCHEDULER.DISABLE(name => 'etl_incremental_job');
    DBMS_OUTPUT.PUT_LINE('Disabled: etl_incremental_job');
    
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR disabling jobs: ' || SQLERRM);
        RAISE;
END sp_disable_etl_jobs;
/

-- ============================================================================
-- MANUAL JOB EXECUTION
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_run_etl_now (
    p_run_type IN VARCHAR2 DEFAULT 'FULL'
) IS
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Starting manual ETL execution...');
    DBMS_OUTPUT.PUT_LINE('Run Type: ' || p_run_type);
    DBMS_OUTPUT.PUT_LINE('');
    
    sp_master_etl(p_run_type => p_run_type, p_send_email => 'Y');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
        RAISE;
END sp_run_etl_now;
/

-- ============================================================================
-- BACKUP & RECOVERY PROCEDURES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_backup_reporting_tables IS
    v_timestamp VARCHAR2(14) := TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS');
BEGIN
    DBMS_OUTPUT.PUT_LINE('Creating backup tables as of ' || v_timestamp);
    
    -- Backup fact table
    EXECUTE IMMEDIATE 'CREATE TABLE fact_sales_bak_' || v_timestamp || ' AS SELECT * FROM fact_sales';
    DBMS_OUTPUT.PUT_LINE('✓ Backed up FACT_SALES');
    
    -- Backup dimensions
    EXECUTE IMMEDIATE 'CREATE TABLE dim_customer_bak_' || v_timestamp || ' AS SELECT * FROM dim_customer';
    DBMS_OUTPUT.PUT_LINE('✓ Backed up DIM_CUSTOMER');
    
    EXECUTE IMMEDIATE 'CREATE TABLE dim_product_bak_' || v_timestamp || ' AS SELECT * FROM dim_product';
    DBMS_OUTPUT.PUT_LINE('✓ Backed up DIM_PRODUCT');
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Backup completed at ' || v_timestamp);
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in backup: ' || SQLERRM);
        RAISE;
END sp_backup_reporting_tables;
/

-- ============================================================================
-- CLEANUP OLD DATA
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_cleanup_old_staging (
    p_days_to_keep IN NUMBER DEFAULT 30
) IS
    v_deleted NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Cleaning staging tables (keeping last ' || p_days_to_keep || ' days)');
    
    DELETE FROM stg_customers WHERE load_timestamp < SYSDATE - p_days_to_keep;
    v_deleted := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('Deleted ' || v_deleted || ' old staging customers');
    
    DELETE FROM stg_orders WHERE load_timestamp < SYSDATE - p_days_to_keep;
    v_deleted := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('Deleted ' || v_deleted || ' old staging orders');
    
    DELETE FROM stg_products WHERE load_timestamp < SYSDATE - p_days_to_keep;
    v_deleted := SQL%ROWCOUNT;
    DBMS_OUTPUT.PUT_LINE('Deleted ' || v_deleted || ' old staging products');
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Staging cleanup completed');
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR in cleanup: ' || SQLERRM);
        RAISE;
END sp_cleanup_old_staging;
/

COMMIT;
