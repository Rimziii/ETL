-- 
-- 03_VALIDATION_FUNCTIONS.sql
-- All data validation and quality checking functions
-- 


-- EMAIL VALIDATION

CREATE OR REPLACE FUNCTION fn_validate_email (
    p_email IN VARCHAR2
) RETURN VARCHAR2 IS
    v_pattern VARCHAR2(500) := '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}$';
BEGIN
    IF p_email IS NULL THEN
        RETURN 'N';
    END IF;
    
    IF REGEXP_LIKE(p_email, v_pattern) THEN
        RETURN 'Y';
    ELSE
        RETURN 'N';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_email;
/

-- 
-- PHONE NUMBER VALIDATION (US Format)

CREATE OR REPLACE FUNCTION fn_validate_phone (
    p_phone IN VARCHAR2
) RETURN VARCHAR2 IS
    v_cleaned VARCHAR2(20);
    v_pattern VARCHAR2(50) := '^\d{3}-\d{3}-\d{4}$|^(\d{10})$';
BEGIN
    IF p_phone IS NULL THEN
        RETURN 'N';
    END IF;
    
    -- Remove common formatting
    v_cleaned := REGEXP_REPLACE(p_phone, '[^\d]', '');
    
    -- Check if exactly 10 digits
    IF LENGTH(v_cleaned) = 10 AND REGEXP_LIKE(v_cleaned, '^\d{10}$') THEN
        RETURN 'Y';
    ELSE
        RETURN 'N';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_phone;
/

-- ============================================================================
-- ZIP CODE VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_validate_zip (
    p_zip IN VARCHAR2,
    p_country IN VARCHAR2 DEFAULT 'US'
) RETURN VARCHAR2 IS
BEGIN
    IF p_zip IS NULL THEN
        RETURN 'N';
    END IF;
    
    CASE p_country
        WHEN 'US' THEN
            -- US: 5 digits or 5+4
            IF REGEXP_LIKE(p_zip, '^\d{5}(-\d{4})?$') THEN
                RETURN 'Y';
            ELSE
                RETURN 'N';
            END IF;
        WHEN 'CA' THEN
            -- Canada: A1A 1A1 format
            IF REGEXP_LIKE(p_zip, '^[A-Z]\d[A-Z] ?\d[A-Z]\d$') THEN
                RETURN 'Y';
            ELSE
                RETURN 'N';
            END IF;
        WHEN 'UK' THEN
            -- UK postcodes are complex, simplified check
            IF LENGTH(p_zip) >= 6 AND LENGTH(p_zip) <= 8 THEN
                RETURN 'Y';
            ELSE
                RETURN 'N';
            END IF;
        ELSE
            RETURN 'Y'; -- Accept if country not recognized
    END CASE;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_zip;
/

-- ============================================================================
-- DATE RANGE VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_validate_date_range (
    p_check_date IN DATE,
    p_min_date IN DATE DEFAULT NULL,
    p_max_date IN DATE DEFAULT NULL,
    p_not_future IN VARCHAR2 DEFAULT 'Y'
) RETURN VARCHAR2 IS
BEGIN
    IF p_check_date IS NULL THEN
        RETURN 'N';
    END IF;
    
    -- Check if date is in future when not allowed
    IF p_not_future = 'Y' AND p_check_date > TRUNC(SYSDATE) THEN
        RETURN 'N';
    END IF;
    
    -- Check min date
    IF p_min_date IS NOT NULL AND p_check_date < p_min_date THEN
        RETURN 'N';
    END IF;
    
    -- Check max date
    IF p_max_date IS NOT NULL AND p_check_date > p_max_date THEN
        RETURN 'N';
    END IF;
    
    RETURN 'Y';
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_date_range;
/

-- ============================================================================
-- NUMERIC RANGE VALIDATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_validate_numeric_range (
    p_value IN NUMBER,
    p_min_value IN NUMBER DEFAULT NULL,
    p_max_value IN NUMBER DEFAULT NULL,
    p_exclude_zero IN VARCHAR2 DEFAULT 'Y'
) RETURN VARCHAR2 IS
BEGIN
    IF p_value IS NULL THEN
        RETURN 'N';
    END IF;
    
    -- Check if zero excluded
    IF p_exclude_zero = 'Y' AND p_value = 0 THEN
        RETURN 'N';
    END IF;
    
    -- Check min value
    IF p_min_value IS NOT NULL AND p_value < p_min_value THEN
        RETURN 'N';
    END IF;
    
    -- Check max value
    IF p_max_value IS NOT NULL AND p_value > p_max_value THEN
        RETURN 'N';
    END IF;
    
    RETURN 'Y';
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_numeric_range;
/

-- ============================================================================
-- PRICE VALIDATION (Price > Cost)
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_validate_pricing (
    p_cost IN NUMBER,
    p_price IN NUMBER,
    p_min_margin_percent IN NUMBER DEFAULT 10
) RETURN VARCHAR2 IS
    v_margin_percent NUMBER(5,2);
BEGIN
    IF p_cost IS NULL OR p_price IS NULL THEN
        RETURN 'N';
    END IF;
    
    IF p_cost <= 0 OR p_price <= 0 THEN
        RETURN 'N';
    END IF;
    
    -- Price must be > cost
    IF p_price <= p_cost THEN
        RETURN 'N';
    END IF;
    
    -- Check minimum margin
    v_margin_percent := ROUND((p_price - p_cost) / p_cost * 100, 2);
    IF v_margin_percent < p_min_margin_percent THEN
        RETURN 'N';
    END IF;
    
    RETURN 'Y';
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_validate_pricing;
/

-- ============================================================================
-- TEXT STANDARDIZATION FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_standardize_customer_type (
    p_customer_type IN VARCHAR2
) RETURN VARCHAR2 IS
BEGIN
    RETURN CASE UPPER(TRIM(p_customer_type))
        WHEN 'RETAIL' THEN 'RETAIL'
        WHEN 'WHOLESALE' THEN 'WHOLESALE'
        WHEN 'ENTERPRISE' THEN 'ENTERPRISE'
        WHEN 'GOVT' THEN 'GOVERNMENT'
        WHEN 'GOVERNMENT' THEN 'GOVERNMENT'
        WHEN 'BUSINESS' THEN 'WHOLESALE'
        WHEN 'B2B' THEN 'WHOLESALE'
        WHEN 'B2C' THEN 'RETAIL'
        WHEN 'CONSUMER' THEN 'RETAIL'
        WHEN 'CORP' THEN 'ENTERPRISE'
        WHEN 'CORPORATE' THEN 'ENTERPRISE'
        ELSE 'UNKNOWN'
    END;
END fn_standardize_customer_type;
/

-- ============================================================================
-- CATEGORY STANDARDIZATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_standardize_category (
    p_category IN VARCHAR2
) RETURN VARCHAR2 IS
BEGIN
    RETURN CASE UPPER(TRIM(p_category))
        WHEN 'ELECTRONICS' THEN 'ELECTRONICS'
        WHEN 'ELEC' THEN 'ELECTRONICS'
        WHEN 'PHONES' THEN 'ELECTRONICS'
        WHEN 'COMPUTERS' THEN 'ELECTRONICS'
        WHEN 'APPAREL' THEN 'APPAREL'
        WHEN 'CLOTHING' THEN 'APPAREL'
        WHEN 'CLOTHES' THEN 'APPAREL'
        WHEN 'FASHION' THEN 'APPAREL'
        WHEN 'FURNITURE' THEN 'FURNITURE'
        WHEN 'HOME' THEN 'FURNITURE'
        WHEN 'FOOD' THEN 'FOOD & BEVERAGE'
        WHEN 'BEVERAGE' THEN 'FOOD & BEVERAGE'
        WHEN 'FOOD & BEVERAGE' THEN 'FOOD & BEVERAGE'
        WHEN 'GROCERIES' THEN 'FOOD & BEVERAGE'
        WHEN 'SPORTS' THEN 'SPORTS & OUTDOORS'
        WHEN 'OUTDOOR' THEN 'SPORTS & OUTDOORS'
        WHEN 'OUTDOORS' THEN 'SPORTS & OUTDOORS'
        ELSE 'OTHER'
    END;
END fn_standardize_category;
/

-- ============================================================================
-- PAYMENT METHOD STANDARDIZATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_standardize_payment_method (
    p_method IN VARCHAR2
) RETURN VARCHAR2 IS
BEGIN
    RETURN CASE UPPER(TRIM(p_method))
        WHEN 'CC' THEN 'CREDIT_CARD'
        WHEN 'CREDIT' THEN 'CREDIT_CARD'
        WHEN 'CREDIT CARD' THEN 'CREDIT_CARD'
        WHEN 'VISA' THEN 'CREDIT_CARD'
        WHEN 'MASTERCARD' THEN 'CREDIT_CARD'
        WHEN 'AMEX' THEN 'CREDIT_CARD'
        WHEN 'ACH' THEN 'BANK_TRANSFER'
        WHEN 'BANK' THEN 'BANK_TRANSFER'
        WHEN 'WIRE' THEN 'BANK_TRANSFER'
        WHEN 'BANK TRANSFER' THEN 'BANK_TRANSFER'
        WHEN 'CASH' THEN 'CASH'
        WHEN 'CHECK' THEN 'CHECK'
        WHEN 'PAYPAL' THEN 'DIGITAL_WALLET'
        WHEN 'DIGITAL' THEN 'DIGITAL_WALLET'
        ELSE 'OTHER'
    END;
END fn_standardize_payment_method;
/

-- ============================================================================
-- ORDER STATUS STANDARDIZATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_standardize_order_status (
    p_status IN VARCHAR2
) RETURN VARCHAR2 IS
BEGIN
    RETURN CASE UPPER(TRIM(p_status))
        WHEN 'PENDING' THEN 'PENDING'
        WHEN 'NEW' THEN 'PENDING'
        WHEN 'SUBMITTED' THEN 'PENDING'
        WHEN 'PROCESSING' THEN 'PROCESSING'
        WHEN 'IN PROGRESS' THEN 'PROCESSING'
        WHEN 'SHIPPED' THEN 'SHIPPED'
        WHEN 'IN TRANSIT' THEN 'SHIPPED'
        WHEN 'DELIVERED' THEN 'COMPLETED'
        WHEN 'COMPLETED' THEN 'COMPLETED'
        WHEN 'DONE' THEN 'COMPLETED'
        WHEN 'CANCELLED' THEN 'CANCELLED'
        WHEN 'CANCEL' THEN 'CANCELLED'
        WHEN 'REFUNDED' THEN 'CANCELLED'
        WHEN 'HELD' THEN 'PENDING'
        WHEN 'FAILED' THEN 'FAILED'
        WHEN 'ERROR' THEN 'FAILED'
        ELSE 'UNKNOWN'
    END;
END fn_standardize_order_status;
/

-- ============================================================================
-- DUPLICATE DETECTION (Using Hash)
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_detect_duplicate (
    p_customer_id IN VARCHAR2,
    p_order_id IN VARCHAR2,
    p_amount IN NUMBER,
    p_order_date IN DATE
) RETURN VARCHAR2 IS
    v_count NUMBER;
BEGIN
    -- Check if same order from same customer on same date with same amount
    SELECT COUNT(*) INTO v_count
    FROM clean_orders
    WHERE clean_customer_id IN (
        SELECT clean_customer_id FROM clean_customers 
        WHERE source_customer_id = p_customer_id
    )
    AND source_order_id = p_order_id
    AND final_amount = p_amount
    AND order_date = p_order_date
    AND is_duplicate = 'N';
    
    IF v_count > 0 THEN
        RETURN 'Y'; -- Duplicate found
    ELSE
        RETURN 'N'; -- No duplicate
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'N';
END fn_detect_duplicate;
/

-- ============================================================================
-- DATA QUALITY SCORE CALCULATION
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_calculate_quality_score (
    p_email_valid IN VARCHAR2,
    p_phone_valid IN VARCHAR2,
    p_address_filled IN VARCHAR2,
    p_null_count IN NUMBER,
    p_total_fields IN NUMBER
) RETURN NUMBER IS
    v_score NUMBER(3,0) := 100;
    v_null_percent NUMBER(5,2);
BEGIN
    -- Deduct points for invalid email
    IF p_email_valid = 'N' THEN
        v_score := v_score - 15;
    END IF;
    
    -- Deduct points for invalid phone
    IF p_phone_valid = 'N' THEN
        v_score := v_score - 10;
    END IF;
    
    -- Deduct points for missing address
    IF p_address_filled = 'N' THEN
        v_score := v_score - 10;
    END IF;
    
    -- Deduct points proportional to null counts
    IF p_total_fields > 0 THEN
        v_null_percent := (p_null_count / p_total_fields) * 100;
        v_score := v_score - ROUND(v_null_percent / 2, 0);
    END IF;
    
    -- Ensure score is between 0-100
    v_score := GREATEST(0, LEAST(100, v_score));
    
    RETURN v_score;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_calculate_quality_score;
/

-- ============================================================================
-- CALCULATE PROFIT METRICS
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_calculate_profit (
    p_quantity IN NUMBER,
    p_unit_price IN NUMBER,
    p_unit_cost IN NUMBER
) RETURN NUMBER IS
    v_profit NUMBER(15,2);
BEGIN
    IF p_quantity IS NULL OR p_unit_price IS NULL OR p_unit_cost IS NULL THEN
        RETURN 0;
    END IF;
    
    v_profit := (p_unit_price - p_unit_cost) * p_quantity;
    RETURN ROUND(v_profit, 2);
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_calculate_profit;
/

-- ============================================================================
-- CALCULATE PROFIT PERCENT
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_calculate_profit_percent (
    p_unit_cost IN NUMBER,
    p_unit_price IN NUMBER
) RETURN NUMBER IS
    v_percent NUMBER(5,2);
BEGIN
    IF p_unit_cost IS NULL OR p_unit_price IS NULL THEN
        RETURN 0;
    END IF;
    
    IF p_unit_cost = 0 THEN
        RETURN 0;
    END IF;
    
    v_percent := ROUND((p_unit_price - p_unit_cost) / p_unit_cost * 100, 2);
    RETURN GREATEST(0, v_percent);
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END fn_calculate_profit_percent;
/

-- ============================================================================
-- GET DATE SK FROM DATE
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_get_date_sk (
    p_date IN DATE
) RETURN NUMBER IS
    v_date_sk NUMBER;
BEGIN
    IF p_date IS NULL THEN
        RETURN -1; -- Unknown date key
    END IF;
    
    SELECT date_id INTO v_date_sk
    FROM dim_date
    WHERE date_value = TRUNC(p_date)
    AND ROWNUM = 1;
    
    RETURN v_date_sk;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN -1; -- Date not in dimension
    WHEN OTHERS THEN
        RETURN -1;
END fn_get_date_sk;
/

-- ============================================================================
-- VALIDATION AGGREGATE PROCEDURES
-- ============================================================================

CREATE OR REPLACE PROCEDURE sp_validate_staging_customers IS
    v_total NUMBER := 0;
    v_valid NUMBER := 0;
    v_invalid NUMBER := 0;
    v_quality_id NUMBER;
BEGIN
    -- Count records
    SELECT COUNT(*) INTO v_total FROM stg_customers;
    
    -- Count valid records (email OR phone valid, and name not null)
    SELECT COUNT(*) INTO v_valid
    FROM stg_customers
    WHERE customer_name IS NOT NULL
    AND (fn_validate_email(email) = 'Y' OR fn_validate_phone(phone) = 'Y');
    
    v_invalid := v_total - v_valid;
    
    -- Log results
    INSERT INTO data_quality_metrics (
        table_name, check_name, records_checked, records_passed, 
        records_failed, pass_percentage, status
    ) VALUES (
        'STG_CUSTOMERS', 'CUSTOMER_VALIDATION',
        v_total, v_valid, v_invalid,
        ROUND((v_valid / NULLIF(v_total, 0)) * 100, 2),
        CASE WHEN (v_valid / NULLIF(v_total, 0)) >= 0.95 THEN 'PASS' ELSE 'FAIL' END
    );
    
    COMMIT;
    
    DBMS_OUTPUT.PUT_LINE('Staging Customers Validation: ' || v_valid || '/' || v_total || ' valid');
EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO error_log (procedure_name, error_code, error_message)
        VALUES ('sp_validate_staging_customers', SQLCODE, SQLERRM);
        COMMIT;
        RAISE;
END sp_validate_staging_customers;
/

-- ============================================================================
-- TESTING VALIDATION FUNCTIONS
-- ============================================================================

BEGIN
    -- Test email validation
    DBMS_OUTPUT.PUT_LINE('Email Validation:');
    DBMS_OUTPUT.PUT_LINE('  john@example.com: ' || fn_validate_email('john@example.com'));
    DBMS_OUTPUT.PUT_LINE('  invalid.email: ' || fn_validate_email('invalid.email'));
    
    -- Test phone validation
    DBMS_OUTPUT.PUT_LINE('Phone Validation:');
    DBMS_OUTPUT.PUT_LINE('  5551234567: ' || fn_validate_phone('5551234567'));
    DBMS_OUTPUT.PUT_LINE('  555-123-4567: ' || fn_validate_phone('555-123-4567'));
    DBMS_OUTPUT.PUT_LINE('  123: ' || fn_validate_phone('123'));
    
    -- Test standardization
    DBMS_OUTPUT.PUT_LINE('Standardization:');
    DBMS_OUTPUT.PUT_LINE('  RETAIL -> ' || fn_standardize_customer_type('retail'));
    DBMS_OUTPUT.PUT_LINE('  B2B -> ' || fn_standardize_customer_type('B2B'));
    DBMS_OUTPUT.PUT_LINE('  Electronics -> ' || fn_standardize_category('Electronics'));
END;
/

COMMIT;
