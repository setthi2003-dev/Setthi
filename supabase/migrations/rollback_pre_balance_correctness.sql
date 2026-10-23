-- =============================================================================
-- ROLLBACK MIGRATION: Pre-Balance Correctness Snapshots
-- Saved on: 2026-10-10
-- Contains original function and view definitions prior to balance fixes
-- =============================================================================

-- 1. classify_transactions
CREATE OR REPLACE FUNCTION public.classify_transactions(p_user_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- 1. FIXED & is_recurring = TRUE
  UPDATE public.bank_transactions
  SET 
    spend_tier = 'FIXED',
    is_recurring = TRUE
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND UPPER(type) = 'DEBIT'
    AND (
      clean_merchant_name ~* '(netflix|spotify|apple|google play|cult\\.fit|cultfit|prime|amazon prime|hotstar|youtube premium|airtel|jio|vi |vodafone|rent|broadband|wifi|act fibernet|tata play)'
      OR narration ~* '(netflix|spotify|apple\\.com|google.*play|cult\\.fit|cultfit|prime video|hotstar|youtube.*prem|airtel|jio.*recharge|rent|broadband|actcorp|tatasky|tataplay)'
      OR category ILIKE '%subscription%'
      OR category ILIKE '%rent%'
      OR category ILIKE '%telecom%'
    );

  -- 2. IMPULSE
  UPDATE public.bank_transactions
  SET spend_tier = 'IMPULSE'
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND UPPER(type) = 'DEBIT'
    AND spend_tier <> 'FIXED'
    AND (
      (
        (
          clean_merchant_name ~* '(swiggy|zomato|zepto|blinkit|instamart|bbnow|bigbasket|dunzo)'
          OR narration ~* '(swiggy|zomato|zepto|blinkit|instamart|bbnow|dunzo)'
          OR category ILIKE '%quick%commerce%'
          OR category ILIKE '%food%'
          OR category ILIKE '%dining%'
        )
        AND (
          EXTRACT(HOUR FROM (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')) >= 23 
          OR EXTRACT(HOUR FROM (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')) < 4
        )
      )
      OR
      (
        amount < 300
        AND (
          clean_merchant_name ~* '(swiggy|zomato|zepto|blinkit|instamart|eats|starbucks|mcdonald|chaayos|chai point|burger king|kfc|pizza hut|domino)'
          OR narration ~* '(swiggy|zomato|zepto|blinkit|instamart|starbucks|mcdonald|chaayos|chai point|burger king|kfc|pizza hut|domino)'
          OR category ILIKE '%dining%'
          OR category ILIKE '%quick%commerce%'
          OR category ILIKE '%cafe%'
          OR category ILIKE '%food%'
        )
      )
    );

  -- 3. ESSENTIAL
  UPDATE public.bank_transactions
  SET spend_tier = 'ESSENTIAL'
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND UPPER(type) = 'DEBIT'
    AND spend_tier NOT IN ('FIXED', 'IMPULSE')
    AND (
      clean_merchant_name ~* '(grocery|groceries|supermarket|dmart|nature basket|reliance fresh|apollo|pharmacy|medplus|netmeds|1mg|fuel|petrol|hpcl|bpcl|ioc|shell|electricity|bescom|cesc|tneb|mseb|bses|water|gas|metro|irctc|uber|ola)'
      OR narration ~* '(grocery|dmart|apollo|medplus|pharmacy|fuel|petrol|hpcl|bpcl|ioc|shell|electric|bescom|hospital|clinic|metro|irctc)'
      OR category ILIKE '%grocer%'
      OR category ILIKE '%utilit%'
      OR category ILIKE '%fuel%'
      OR category ILIKE '%transport%'
      OR category ILIKE '%medic%'
      OR category ILIKE '%health%'
    );

  -- 4. GENERAL
  UPDATE public.bank_transactions
  SET spend_tier = 'GENERAL'
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND spend_tier NOT IN ('FIXED', 'IMPULSE', 'ESSENTIAL');

END;
$function$;

-- 2. get_cashflow_rhythm
CREATE OR REPLACE FUNCTION public.get_cashflow_rhythm(p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_now TIMESTAMPTZ := NOW() AT TIME ZONE 'Asia/Kolkata';
  v_anchor TIMESTAMPTZ;
  v_is_live BOOLEAN := FALSE;
  v_latest_ts TIMESTAMPTZ;
  v_balance NUMERIC := 0.0;
  
  -- User Profile Calibration
  v_income_type TEXT;
  v_expected_income NUMERIC := 0.0;
  
  -- Inflow rhythm & cycle dates
  v_next_income_date DATE;
  v_cycle_start DATE;
  v_days_to_next_inflow INT := 30;
  v_detected_payday INT;
  
  -- Committed bills
  v_upcoming_bills_total NUMERIC := 0.0;
  v_upcoming_bills_count INT := 0;
  v_bills_json JSONB := '[]'::jsonb;
  
  -- Spending Velocity
  v_spent_today NUMERIC := 0.0;
  v_spent_this_week NUMERIC := 0.0;
  v_days_left_in_week INT := 1;
  
  -- Outputs
  v_safe_pool NUMERIC := 0.0;
  v_safe_today NUMERIC := 0.0;
  v_safe_week NUMERIC := 0.0;
  v_runway_days INT := 999;
  v_daily_velocity NUMERIC := 0.0;
  v_health_status TEXT := 'HEALTHY';
  
  v_dummy JSONB;
BEGIN
  IF auth.role() = 'authenticated' AND auth.uid() IS NOT NULL THEN
    v_uid := auth.uid();
  END IF;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT public.sync_detected_recurring_commitments(v_uid) INTO v_dummy;

  SELECT income_type, COALESCE(expected_monthly_income, 0.0)
  INTO v_income_type, v_expected_income
  FROM public.profiles
  WHERE id = v_uid;
  v_income_type := COALESCE(v_income_type, 'Salaried');

  SELECT current_balance, transaction_timestamp 
  INTO v_balance, v_latest_ts
  FROM public.bank_transactions
  WHERE user_id = v_uid AND current_balance IS NOT NULL
  ORDER BY transaction_timestamp DESC, created_at DESC
  LIMIT 1;

  IF v_balance IS NULL THEN
    SELECT current_balance INTO v_balance
    FROM public.bank_accounts
    WHERE user_id = v_uid AND status = 'ACTIVE'
    ORDER BY updated_at DESC
    LIMIT 1;
  END IF;
  v_balance := COALESCE(v_balance, 0.0);

  IF v_latest_ts IS NOT NULL AND (v_now - (v_latest_ts AT TIME ZONE 'Asia/Kolkata')) <= INTERVAL '7 days' THEN
    v_anchor := v_now;
    v_is_live := TRUE;
  ELSIF v_latest_ts IS NOT NULL THEN
    v_anchor := v_latest_ts AT TIME ZONE 'Asia/Kolkata';
    v_is_live := FALSE;
  ELSE
    v_anchor := v_now;
    v_is_live := TRUE;
  END IF;

  IF v_income_type = 'Salaried' OR v_income_type = 'Allowance' THEN
    SELECT EXTRACT(DAY FROM transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::INT
    INTO v_detected_payday
    FROM public.bank_transactions
    WHERE user_id = v_uid 
      AND UPPER(type) = 'CREDIT'
      AND (v_expected_income <= 0 OR amount >= (v_expected_income * 0.5))
    GROUP BY EXTRACT(DAY FROM transaction_timestamp AT TIME ZONE 'Asia/Kolkata')
    ORDER BY COUNT(*) DESC, MAX(transaction_timestamp) DESC
    LIMIT 1;

    v_detected_payday := COALESCE(v_detected_payday, 1);

    IF EXTRACT(DAY FROM v_anchor)::INT < v_detected_payday THEN
      v_next_income_date := MAKE_DATE(
        EXTRACT(YEAR FROM v_anchor)::INT,
        EXTRACT(MONTH FROM v_anchor)::INT,
        LEAST(v_detected_payday, 28)
      );
    ELSE
      v_next_income_date := (DATE_TRUNC('month', v_anchor) + INTERVAL '1 month')::DATE + (LEAST(v_detected_payday, 28) - 1);
    END IF;

    v_days_to_next_inflow := GREATEST(1, (v_next_income_date - v_anchor::DATE));
  ELSE
    v_next_income_date := (v_anchor::DATE + 30);
    v_days_to_next_inflow := 30;
  END IF;

  SELECT 
    COALESCE(SUM(expected_amount), 0.0),
    COUNT(*)::INT,
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', id,
        'merchant_name', merchant_name,
        'expected_amount', expected_amount,
        'category', category,
        'typical_due_day', typical_due_day,
        'is_confirmed', is_confirmed
      ) ORDER BY typical_due_day ASC
    ), '[]'::jsonb)
  INTO v_upcoming_bills_total, v_upcoming_bills_count, v_bills_json
  FROM public.user_recurring_commitments
  WHERE user_id = v_uid
    AND is_active = TRUE
    AND (last_paid_at IS NULL OR (v_anchor - last_paid_at) > INTERVAL '25 days');

  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_spent_today
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND is_recurring = FALSE
    AND transaction_timestamp >= DATE_TRUNC('day', v_anchor)
    AND transaction_timestamp <= v_anchor;

  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_spent_this_week
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND is_recurring = FALSE
    AND transaction_timestamp >= DATE_TRUNC('week', v_anchor)
    AND transaction_timestamp <= v_anchor;

  v_days_left_in_week := GREATEST(1, (7 - EXTRACT(ISODOW FROM v_anchor)::INT + 1));

  v_safe_pool := GREATEST(0.0, v_balance - v_upcoming_bills_total);

  IF v_days_to_next_inflow > 0 THEN
    v_safe_week := ROUND((v_safe_pool / v_days_to_next_inflow) * v_days_left_in_week, 2);
  ELSE
    v_safe_week := ROUND(v_safe_pool, 2);
  END IF;

  IF v_days_left_in_week > 0 THEN
    v_safe_today := ROUND(GREATEST(0.0, (v_safe_week / v_days_left_in_week) - v_spent_today), 2);
  ELSE
    v_safe_today := ROUND(GREATEST(0.0, v_safe_week - v_spent_today), 2);
  END IF;

  v_safe_week := ROUND(GREATEST(0.0, v_safe_week - v_spent_this_week), 2);

  SELECT COALESCE(ROUND(SUM(amount) / 14.0, 2), 0.0)
  INTO v_daily_velocity
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND transaction_timestamp >= (v_anchor - INTERVAL '14 days')
    AND transaction_timestamp <= v_anchor;

  IF v_daily_velocity > 0 THEN
    v_runway_days := FLOOR(v_balance / v_daily_velocity);
  ELSE
    v_runway_days := 999;
  END IF;

  IF v_balance <= 0 OR v_safe_pool <= 0 THEN
    v_health_status := 'DEFICIT';
  ELSIF v_runway_days < 10 OR (v_daily_velocity > 0 AND v_safe_today < (v_daily_velocity * 0.4)) THEN
    v_health_status := 'CAUTION';
  ELSE
    v_health_status := 'HEALTHY';
  END IF;

  RETURN jsonb_build_object(
    'current_balance', v_balance,
    'safe_to_spend_today', v_safe_today,
    'safe_to_spend_this_week', v_safe_week,
    'spent_today', v_spent_today,
    'spent_this_week', v_spent_this_week,
    'upcoming_bills_total', v_upcoming_bills_total,
    'upcoming_bills_count', v_upcoming_bills_count,
    'upcoming_bills', v_bills_json,
    'days_to_next_inflow', v_days_to_next_inflow,
    'next_inflow_date', TO_CHAR(v_next_income_date, 'DD Mon YYYY'),
    'income_type', v_income_type,
    'runway_days', v_runway_days,
    'daily_velocity', v_daily_velocity,
    'health_status', v_health_status,
    'is_live', v_is_live,
    'anchor_date', v_anchor
  );
END;
$function$;

-- 3. get_cashflow_velocity
CREATE OR REPLACE FUNCTION public.get_cashflow_velocity(p_user_id uuid DEFAULT auth.uid(), p_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_balance NUMERIC := 0.0;
  v_curr_burn NUMERIC := 0.0;
  v_prev_burn NUMERIC := 0.0;
  v_curr_daily NUMERIC := 0.0;
  v_prev_daily NUMERIC := 0.0;
  v_burn_delta NUMERIC := 0.0;
  v_runway INT := 999;
  v_latest_ts TIMESTAMPTZ;
  v_anchor TIMESTAMPTZ;
  v_now TIMESTAMPTZ := NOW() AT TIME ZONE 'Asia/Kolkata';
  v_is_live BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT current_balance, transaction_timestamp 
  INTO v_balance, v_latest_ts
  FROM public.bank_transactions
  WHERE user_id = v_uid AND current_balance IS NOT NULL
  ORDER BY transaction_timestamp DESC, created_at DESC
  LIMIT 1;
  v_balance := COALESCE(v_balance, 0.0);

  IF v_latest_ts IS NOT NULL AND (v_now - (v_latest_ts AT TIME ZONE 'Asia/Kolkata')) <= INTERVAL '7 days' THEN
    v_anchor := v_now;
    v_is_live := TRUE;
  ELSIF v_latest_ts IS NOT NULL THEN
    v_anchor := v_latest_ts;
    v_is_live := FALSE;
  ELSE
    v_anchor := v_now;
    v_is_live := TRUE;
  END IF;

  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_curr_burn
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND transaction_timestamp >= (v_anchor - (p_days || ' days')::INTERVAL)
    AND transaction_timestamp <= v_anchor;

  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_prev_burn
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND transaction_timestamp >= (v_anchor - ((p_days * 2) || ' days')::INTERVAL)
    AND transaction_timestamp < (v_anchor - (p_days || ' days')::INTERVAL);

  v_curr_daily := ROUND(v_curr_burn / p_days, 2);
  v_prev_daily := ROUND(v_prev_burn / p_days, 2);

  IF v_prev_daily > 0 THEN
    v_burn_delta := ROUND(((v_curr_daily - v_prev_daily) / v_prev_daily * 100.0), 1);
  ELSE
    v_burn_delta := 0.0;
  END IF;

  IF v_curr_daily > 0 THEN
    v_runway := FLOOR(v_balance / v_curr_daily);
  ELSE
    v_runway := 999;
  END IF;

  RETURN jsonb_build_object(
    'current_daily_burn', v_curr_daily,
    'previous_daily_burn', v_prev_daily,
    'burn_delta_percent', v_burn_delta,
    'runway_days', v_runway,
    'current_balance', ROUND(v_balance, 2),
    'is_live', v_is_live,
    'anchor_date', v_anchor
  );
END;
$function$;

-- 4. get_current_balance
CREATE OR REPLACE FUNCTION public.get_current_balance(p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_balance NUMERIC;
  v_as_of TIMESTAMPTZ;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT current_balance, transaction_timestamp
  INTO v_balance, v_as_of
  FROM public.bank_transactions
  WHERE user_id = p_user_id AND current_balance IS NOT NULL
  ORDER BY transaction_timestamp DESC, created_at DESC
  LIMIT 1;

  IF v_balance IS NULL THEN
    SELECT current_balance, updated_at
    INTO v_balance, v_as_of
    FROM public.bank_accounts
    WHERE user_id = p_user_id AND status = 'ACTIVE'
    ORDER BY updated_at DESC
    LIMIT 1;
  END IF;

  IF v_balance IS NULL THEN
    RETURN jsonb_build_object(
      'current_balance', 0.0,
      'as_of_date', NOW(),
      'note', 'No linked bank accounts or transactions recorded yet'
    );
  END IF;

  RETURN jsonb_build_object(
    'current_balance', ROUND(v_balance, 2),
    'as_of_date', v_as_of
  );
END;
$function$;

-- 5. get_safe_to_spend
CREATE OR REPLACE FUNCTION public.get_safe_to_spend(p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_balance NUMERIC := 0.0;
  v_pending_recurring NUMERIC := 0.0;
  v_days_remaining INT := 1;
  v_safe_total NUMERIC := 0.0;
  v_safe_daily NUMERIC := 0.0;
  v_now TIMESTAMPTZ := NOW() AT TIME ZONE 'Asia/Kolkata';
  v_latest_ts TIMESTAMPTZ;
  v_anchor_date TIMESTAMPTZ;
  v_end_of_month DATE;
  v_is_live BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT current_balance, transaction_timestamp 
  INTO v_balance, v_latest_ts
  FROM public.bank_transactions
  WHERE user_id = v_uid AND current_balance IS NOT NULL
  ORDER BY transaction_timestamp DESC, created_at DESC
  LIMIT 1;

  IF v_balance IS NULL THEN
    SELECT current_balance INTO v_balance
    FROM public.bank_accounts
    WHERE user_id = v_uid AND status = 'ACTIVE'
    ORDER BY updated_at DESC
    LIMIT 1;
  END IF;
  v_balance := COALESCE(v_balance, 0.0);

  IF v_latest_ts IS NOT NULL AND (v_now - (v_latest_ts AT TIME ZONE 'Asia/Kolkata')) <= INTERVAL '7 days' THEN
    v_anchor_date := v_now;
    v_is_live := TRUE;
  ELSIF v_latest_ts IS NOT NULL THEN
    v_anchor_date := v_latest_ts AT TIME ZONE 'Asia/Kolkata';
    v_is_live := FALSE;
  ELSE
    v_anchor_date := v_now;
    v_is_live := TRUE;
  END IF;

  v_end_of_month := (DATE_TRUNC('month', v_anchor_date) + INTERVAL '1 month' - INTERVAL '1 day')::DATE;
  v_days_remaining := GREATEST(1, (v_end_of_month - v_anchor_date::DATE + 1));

  SELECT COALESCE(SUM(sub.avg_amount), 0.0)
  INTO v_pending_recurring
  FROM (
    SELECT 
      clean_merchant_name,
      AVG(amount) as avg_amount
    FROM public.bank_transactions
    WHERE user_id = v_uid 
      AND is_recurring = TRUE
      AND UPPER(type) = 'DEBIT'
      AND clean_merchant_name NOT IN (
        SELECT DISTINCT clean_merchant_name 
        FROM public.bank_transactions 
        WHERE user_id = v_uid 
          AND is_recurring = TRUE
          AND transaction_timestamp >= DATE_TRUNC('month', v_anchor_date)
          AND transaction_timestamp <= v_anchor_date
      )
    GROUP BY clean_merchant_name
  ) sub;

  v_safe_total := GREATEST(0.0, v_balance - v_pending_recurring);
  v_safe_daily := ROUND(v_safe_total / v_days_remaining, 2);

  RETURN jsonb_build_object(
    'safe_to_spend_daily', v_safe_daily,
    'safe_to_spend_total', ROUND(v_safe_total, 2),
    'days_remaining', v_days_remaining,
    'pending_recurring_total', ROUND(v_pending_recurring, 2),
    'current_balance', ROUND(v_balance, 2),
    'is_live', v_is_live,
    'active_month', TO_CHAR(v_anchor_date, 'Mon YYYY')
  );
END;
$function$;

-- 6. get_spending_summary
CREATE OR REPLACE FUNCTION public.get_spending_summary(p_category text DEFAULT NULL::text, p_merchant text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date, p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_total NUMERIC := 0.0;
  v_count INT := 0;
  v_top_txns JSONB := '[]'::jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT 
    COALESCE(SUM(amount), 0.0),
    COUNT(*)
  INTO v_total, v_count
  FROM public.bank_transactions
  WHERE user_id = p_user_id
    AND UPPER(type) = 'DEBIT'
    AND (p_category IS NULL OR category ILIKE '%' || p_category || '%')
    AND (p_merchant IS NULL OR clean_merchant_name ILIKE '%' || p_merchant || '%' OR narration ILIKE '%' || p_merchant || '%')
    AND (p_start_date IS NULL OR transaction_timestamp >= p_start_date)
    AND (p_end_date IS NULL OR transaction_timestamp <= (p_end_date + INTERVAL '1 day'));

  SELECT jsonb_agg(sub)
  INTO v_top_txns
  FROM (
    SELECT 
      clean_merchant_name AS merchant,
      ROUND(amount, 2) AS amount,
      category,
      TO_CHAR(transaction_timestamp, 'YYYY-MM-DD') AS date,
      narration
    FROM public.bank_transactions
    WHERE user_id = p_user_id
      AND UPPER(type) = 'DEBIT'
      AND (p_category IS NULL OR category ILIKE '%' || p_category || '%')
      AND (p_merchant IS NULL OR clean_merchant_name ILIKE '%' || p_merchant || '%' OR narration ILIKE '%' || p_merchant || '%')
      AND (p_start_date IS NULL OR transaction_timestamp >= p_start_date)
      AND (p_end_date IS NULL OR transaction_timestamp <= (p_end_date + INTERVAL '1 day'))
    ORDER BY amount DESC
    LIMIT 3
  ) sub;

  RETURN jsonb_build_object(
    'total_spent', ROUND(v_total, 2),
    'transaction_count', v_count,
    'top_transactions', COALESCE(v_top_txns, '[]'::jsonb),
    'category_filter', p_category,
    'merchant_filter', p_merchant,
    'start_date', p_start_date,
    'end_date', p_end_date
  );
END;
$function$;

-- 7. get_telemetry_metrics
CREATE OR REPLACE FUNCTION public.get_telemetry_metrics(p_user_id uuid DEFAULT auth.uid(), p_period text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_start_time TIMESTAMPTZ := NULL;
  v_end_time TIMESTAMPTZ := NULL;
  v_now TIMESTAMPTZ := NOW() AT TIME ZONE 'Asia/Kolkata';
  v_month_start TIMESTAMPTZ := DATE_TRUNC('month', v_now);
  v_period_days INT := 30;
  v_inflow NUMERIC := 0.0;
  v_spent NUMERIC := 0.0;
  v_impulse NUMERIC := 0.0;
  v_savings_ratio NUMERIC := 0.0;
  v_disc_ratio NUMERIC := 0.0;
  v_daily_velocity NUMERIC := 0.0;
  v_health_score INT := 50;
  v_channel_dist JSONB := '[]'::jsonb;
  v_category_dist JSONB := '[]'::jsonb;
  v_weekly_outflow JSONB := '[]'::jsonb;
  v_earliest_txn TIMESTAMPTZ;
  v_latest_txn TIMESTAMPTZ;
  v_latest_debit TIMESTAMPTZ;
  v_last_ingested TIMESTAMPTZ;
  v_target_month TIMESTAMPTZ;
  v_type_filter TEXT := NULL;
  v_is_live BOOLEAN := FALSE;
  v_period_label TEXT := 'All Time';
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT 
    MIN(transaction_timestamp), 
    MAX(transaction_timestamp),
    MAX(CASE WHEN UPPER(type) = 'DEBIT' THEN transaction_timestamp ELSE NULL END),
    MAX(created_at)
  INTO v_earliest_txn, v_latest_txn, v_latest_debit, v_last_ingested
  FROM public.bank_transactions
  WHERE user_id = v_uid;

  v_is_live := (v_latest_txn IS NOT NULL AND (v_now - (v_latest_txn AT TIME ZONE 'Asia/Kolkata')) <= INTERVAL '7 days');

  IF p_period = 'month' THEN
    IF EXISTS (SELECT 1 FROM public.bank_transactions WHERE user_id = v_uid AND transaction_timestamp >= v_month_start) THEN
      v_start_time := v_month_start;
      v_period_days := GREATEST(1, EXTRACT(DAY FROM v_now)::INT);
      v_period_label := TO_CHAR(v_now, 'Mon YYYY');
    ELSIF v_latest_txn IS NOT NULL THEN
      v_start_time := DATE_TRUNC('month', v_latest_txn AT TIME ZONE 'Asia/Kolkata');
      v_end_time := v_start_time + INTERVAL '1 month';
      v_period_days := GREATEST(1, EXTRACT(DAY FROM (v_latest_txn - v_start_time))::INT);
      v_period_label := TO_CHAR(v_start_time, 'Mon YYYY');
    ELSE
      v_start_time := v_month_start;
      v_period_days := 30;
      v_period_label := TO_CHAR(v_now, 'Mon YYYY');
    END IF;
  ELSIF p_period = '7d' THEN
    IF EXISTS (SELECT 1 FROM public.bank_transactions WHERE user_id = v_uid AND transaction_timestamp >= NOW() - INTERVAL '7 days') THEN
      v_start_time := NOW() - INTERVAL '7 days';
      v_period_label := 'Past 7 Days';
    ELSIF v_latest_txn IS NOT NULL THEN
      v_start_time := v_latest_txn - INTERVAL '7 days';
      v_end_time := v_latest_txn + INTERVAL '1 second';
      v_period_label := TO_CHAR(v_start_time, 'DD Mon') || ' - ' || TO_CHAR(v_latest_txn, 'DD Mon YYYY');
    ELSE
      v_start_time := NOW() - INTERVAL '7 days';
      v_period_label := 'Past 7 Days';
    END IF;
    v_period_days := 7;
  ELSIF p_period = 'debits' THEN
    v_type_filter := 'DEBIT';
    v_period_label := 'All Outflows';
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
    ELSE
      v_period_days := 30;
    END IF;
  ELSIF p_period = 'inflow' THEN
    v_type_filter := 'CREDIT';
    v_period_label := 'All Inflows';
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
    ELSE
      v_period_days := 30;
    END IF;
  ELSE
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
      v_period_label := TO_CHAR(v_earliest_txn, 'DD Mon YYYY') || ' - ' || TO_CHAR(v_latest_txn, 'DD Mon YYYY');
    ELSE
      v_period_days := 30;
      v_period_label := 'All Time';
    END IF;
  END IF;

  SELECT 
    COALESCE(SUM(CASE WHEN UPPER(type) = 'CREDIT' THEN amount ELSE 0 END), 0.0),
    COALESCE(SUM(CASE WHEN UPPER(type) = 'DEBIT' THEN amount ELSE 0 END), 0.0),
    COALESCE(SUM(CASE WHEN UPPER(type) = 'DEBIT' AND spend_tier = 'IMPULSE' THEN amount ELSE 0 END), 0.0)
  INTO v_inflow, v_spent, v_impulse
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND (v_start_time IS NULL OR transaction_timestamp >= v_start_time)
    AND (v_end_time IS NULL OR transaction_timestamp < v_end_time)
    AND (v_type_filter IS NULL OR UPPER(type) = v_type_filter);

  IF p_period = 'inflow' THEN
    v_savings_ratio := 1.0;
    v_spent := 0.0;
  ELSIF v_inflow > 0 THEN
    v_savings_ratio := GREATEST(0.0, LEAST(1.0, (v_inflow - v_spent) / v_inflow));
  ELSE
    v_savings_ratio := 0.0;
  END IF;

  IF v_spent > 0 THEN
    v_disc_ratio := ROUND(v_impulse / v_spent, 3);
  ELSE
    v_disc_ratio := 0.0;
  END IF;

  v_daily_velocity := ROUND(v_spent / v_period_days, 2);
  v_health_score := ROUND(LEAST(100.0, GREATEST(0.0, 50.0 + (v_savings_ratio * 30.0) - (v_disc_ratio * 20.0))))::INT;

  SELECT COALESCE(jsonb_agg(row_to_json(ch)), '[]'::jsonb)
  INTO v_channel_dist
  FROM (
    SELECT 
      mode,
      ROUND(SUM(amount), 2) AS amount,
      ROUND(SUM(amount) / NULLIF(SUM(SUM(amount)) OVER (), 0) * 100.0, 1) AS percentage
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND (v_start_time IS NULL OR transaction_timestamp >= v_start_time)
      AND (v_end_time IS NULL OR transaction_timestamp < v_end_time)
      AND (v_type_filter IS NULL OR UPPER(type) = v_type_filter)
    GROUP BY mode
    ORDER BY SUM(amount) DESC
  ) ch;

  SELECT COALESCE(jsonb_agg(row_to_json(cat)), '[]'::jsonb)
  INTO v_category_dist
  FROM (
    SELECT 
      COALESCE(NULLIF(TRIM(category), ''), 'Uncategorized') AS category,
      ROUND(SUM(amount), 2) AS amount,
      COUNT(*)::INT AS count,
      ROUND(SUM(amount) / NULLIF(v_spent, 0) * 100.0, 1) AS percentage
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'DEBIT'
      AND (v_start_time IS NULL OR transaction_timestamp >= v_start_time)
      AND (v_end_time IS NULL OR transaction_timestamp < v_end_time)
    GROUP BY COALESCE(NULLIF(TRIM(category), ''), 'Uncategorized')
    ORDER BY SUM(amount) DESC
  ) cat;

  IF EXISTS (
    SELECT 1 FROM public.bank_transactions 
    WHERE user_id = v_uid 
      AND UPPER(type) = 'DEBIT' 
      AND transaction_timestamp >= v_month_start
  ) THEN
    v_target_month := v_month_start;
  ELSIF v_latest_debit IS NOT NULL THEN
    v_target_month := DATE_TRUNC('month', v_latest_debit AT TIME ZONE 'Asia/Kolkata');
  ELSE
    v_target_month := v_month_start;
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(wk)), '[]'::jsonb)
  INTO v_weekly_outflow
  FROM (
    SELECT
      w.week_num AS week,
      'Week ' || w.week_num AS label,
      COALESCE(ROUND(SUM(bt.amount), 2), 0.0) AS amount
    FROM (
      VALUES 
        (1, 1, 7),
        (2, 8, 14),
        (3, 15, 21),
        (4, 22, 31)
    ) AS w(week_num, start_d, end_d)
    LEFT JOIN public.bank_transactions bt
      ON bt.user_id = v_uid
      AND UPPER(bt.type) = 'DEBIT'
      AND bt.transaction_timestamp >= v_target_month
      AND bt.transaction_timestamp < (v_target_month + INTERVAL '1 month')
      AND EXTRACT(DAY FROM (bt.transaction_timestamp AT TIME ZONE 'Asia/Kolkata')) >= w.start_d
      AND EXTRACT(DAY FROM (bt.transaction_timestamp AT TIME ZONE 'Asia/Kolkata')) <= w.end_d
    GROUP BY w.week_num
    ORDER BY w.week_num ASC
  ) wk;

  RETURN jsonb_build_object(
    'period', p_period,
    'total_inflow', ROUND(v_inflow, 2),
    'total_spent', ROUND(v_spent, 2),
    'impulse_spent', ROUND(v_impulse, 2),
    'savings_ratio', ROUND(v_savings_ratio, 3),
    'discretionary_ratio', v_disc_ratio,
    'daily_velocity', v_daily_velocity,
    'financial_health_score', v_health_score,
    'channel_distribution', v_channel_dist,
    'category_distribution', v_category_dist,
    'weekly_outflow_velocity', v_weekly_outflow,
    'latest_transaction_timestamp', TO_CHAR(v_latest_txn, 'YYYY-MM-DD HH24:MI:SS'),
    'last_synced_at', TO_CHAR(v_last_ingested, 'YYYY-MM-DD HH24:MI:SS'),
    'is_live', v_is_live,
    'statement_period_label', v_period_label
  );
END;
$function$;

-- 8. sync_detected_recurring_commitments
CREATE OR REPLACE FUNCTION public.sync_detected_recurring_commitments(p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_count INT := 0;
  r RECORD;
BEGIN
  IF auth.role() = 'authenticated' AND auth.uid() IS NOT NULL THEN
    v_uid := auth.uid();
  END IF;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  FOR r IN
    SELECT 
      clean_merchant_name AS merchant,
      COALESCE(category, 'Subscription') AS cat,
      ROUND(AVG(amount), 2) AS avg_amount,
      EXTRACT(DAY FROM MAX(transaction_timestamp))::INT AS due_day,
      MAX(transaction_timestamp) AS last_txn
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'DEBIT'
      AND clean_merchant_name IS NOT NULL
      AND (
        is_recurring = TRUE
        OR clean_merchant_name ILIKE ANY(ARRAY[
          '%NETFLIX%', '%SPOTIFY%', '%AMAZON PRIME%', '%APPLE.COM/BILL%',
          '%HOTSTAR%', '%YOUTUBE%', '%AIRTEL%', '%JIO%', '%BROADBAND%',
          '%ELECTRICITY%', '%RENT%', '%SWIGGY ONE%', '%ZOMATO GOLD%',
          '%GYM%', '%FITNESS%', '%INSURANCE%', '%EMI%', '%SIP%'
        ])
      )
    GROUP BY clean_merchant_name, COALESCE(category, 'Subscription')
    HAVING COUNT(*) >= 1
  LOOP
    INSERT INTO public.user_recurring_commitments (
      user_id,
      merchant_name,
      category,
      expected_amount,
      frequency,
      typical_due_day,
      is_active,
      is_confirmed,
      last_paid_at,
      updated_at
    ) VALUES (
      v_uid,
      r.merchant,
      r.cat,
      r.avg_amount,
      'MONTHLY',
      r.due_day,
      TRUE,
      TRUE,
      r.last_txn,
      NOW()
    )
    ON CONFLICT (user_id, merchant_name) 
    DO UPDATE SET
      last_paid_at = GREATEST(public.user_recurring_commitments.last_paid_at, EXCLUDED.last_paid_at),
      expected_amount = CASE 
        WHEN public.user_recurring_commitments.is_confirmed THEN public.user_recurring_commitments.expected_amount 
        ELSE EXCLUDED.expected_amount 
      END,
      updated_at = NOW();
    
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('synced_count', v_count);
END;
$function$;

-- 9. user_financial_snapshot (VIEW)
CREATE OR REPLACE VIEW public.user_financial_snapshot AS
 WITH latest_txns AS (
         SELECT bank_transactions.user_id,
            max(bank_transactions.transaction_timestamp) AS latest_ts,
            min(bank_transactions.transaction_timestamp) AS earliest_ts,
            max(bank_transactions.created_at) AS latest_created_at
           FROM bank_transactions
          GROUP BY bank_transactions.user_id
        ), latest_balance AS (
         SELECT DISTINCT ON (bank_transactions.user_id) bank_transactions.user_id,
            bank_transactions.current_balance
           FROM bank_transactions
          WHERE (bank_transactions.current_balance IS NOT NULL)
          ORDER BY bank_transactions.user_id, bank_transactions.transaction_timestamp DESC, bank_transactions.created_at DESC
        ), agg_7d AS (
         SELECT bt.user_id,
            sum(
                CASE
                    WHEN (upper(bt.type) = 'DEBIT'::text) THEN bt.amount
                    ELSE (0)::numeric
                END) AS spent_last_7d,
            sum(
                CASE
                    WHEN (upper(bt.type) = 'CREDIT'::text) THEN bt.amount
                    ELSE (0)::numeric
                END) AS inflow_last_7d,
            sum(
                CASE
                    WHEN ((upper(bt.type) = 'DEBIT'::text) AND (bt.spend_tier = 'IMPULSE'::text)) THEN bt.amount
                    ELSE (0)::numeric
                END) AS impulse_last_7d
           FROM (bank_transactions bt
             JOIN latest_txns lt_1 ON ((lt_1.user_id = bt.user_id)))
          WHERE ((bt.transaction_timestamp >=
                CASE
                    WHEN ((now() - lt_1.latest_ts) <= '7 days'::interval) THEN (now() - '7 days'::interval)
                    ELSE (lt_1.latest_ts - '7 days'::interval)
                END) AND (bt.transaction_timestamp <=
                CASE
                    WHEN ((now() - lt_1.latest_ts) <= '7 days'::interval) THEN now()
                    ELSE lt_1.latest_ts
                END))
          GROUP BY bt.user_id
        ), top_cat AS (
         SELECT DISTINCT ON (bt.user_id) bt.user_id,
            COALESCE(bt.category, 'General'::text) AS top_category_7d
           FROM (bank_transactions bt
             JOIN latest_txns lt_1 ON ((lt_1.user_id = bt.user_id)))
          WHERE ((upper(bt.type) = 'DEBIT'::text) AND (bt.transaction_timestamp >=
                CASE
                    WHEN ((now() - lt_1.latest_ts) <= '7 days'::interval) THEN (now() - '7 days'::interval)
                    ELSE (lt_1.latest_ts - '7 days'::interval)
                END) AND (bt.transaction_timestamp <=
                CASE
                    WHEN ((now() - lt_1.latest_ts) <= '7 days'::interval) THEN now()
                    ELSE lt_1.latest_ts
                END))
          GROUP BY bt.user_id, COALESCE(bt.category, 'General'::text)
          ORDER BY bt.user_id, (sum(bt.amount)) DESC
        ), recurring_cnt AS (
         SELECT bank_transactions.user_id,
            count(DISTINCT COALESCE(bank_transactions.clean_merchant_name, bank_transactions.narration)) AS active_recurring_count
           FROM bank_transactions
          WHERE ((bank_transactions.is_recurring = true) AND (upper(bank_transactions.type) = 'DEBIT'::text))
          GROUP BY bank_transactions.user_id
        )
 SELECT u.id AS user_id,
    COALESCE(lb.current_balance, 0.0) AS current_balance,
    round(COALESCE(a7.spent_last_7d, 0.0), 2) AS spent_last_7d,
    round(COALESCE(a7.inflow_last_7d, 0.0), 2) AS inflow_last_7d,
    COALESCE(tc.top_category_7d, 'None'::text) AS top_category_7d,
        CASE
            WHEN (COALESCE(a7.spent_last_7d, 0.0) > (0)::numeric) THEN round(((COALESCE(a7.impulse_last_7d, 0.0) / a7.spent_last_7d) * (100)::numeric), 1)
            ELSE 0.0
        END AS impulse_ratio_7d,
    (COALESCE(rc.active_recurring_count, (0)::bigint))::integer AS active_recurring_count,
    round(GREATEST(0.0, (COALESCE(lb.current_balance, 0.0) / 30.0)), 2) AS safe_to_spend_daily,
        CASE
            WHEN ((lt.latest_ts IS NOT NULL) AND ((now() - lt.latest_ts) <= '7 days'::interval)) THEN true
            ELSE false
        END AS is_live_data,
        CASE
            WHEN (lt.latest_ts IS NULL) THEN 'No recent records'::text
            WHEN ((now() - lt.latest_ts) <= '7 days'::interval) THEN 'this week'::text
            ELSE ((to_char((lt.latest_ts - '7 days'::interval), 'DD Mon'::text) || ' - '::text) || to_char(lt.latest_ts, 'DD Mon YYYY'::text))
        END AS statement_period_label,
    lt.latest_ts AS latest_transaction_timestamp,
    lt.latest_created_at
   FROM (((((auth.users u
     LEFT JOIN latest_txns lt ON ((lt.user_id = u.id)))
     LEFT JOIN latest_balance lb ON ((lb.user_id = u.id)))
     LEFT JOIN agg_7d a7 ON ((a7.user_id = u.id)))
     LEFT JOIN top_cat tc ON ((tc.user_id = u.id)))
     LEFT JOIN recurring_cnt rc ON ((rc.user_id = u.id)));
