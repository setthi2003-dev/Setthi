-- =============================================================================
-- Migration: 20261006000001_cashflow_pattern_engine.sql
-- Description: Financial Pattern Engine (Cashflow Rhythm) & Recurring Commitments
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. USER RECURRING COMMITMENTS TABLE
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_recurring_commitments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  merchant_name TEXT NOT NULL,
  category TEXT DEFAULT 'Subscription',
  expected_amount NUMERIC NOT NULL CHECK (expected_amount >= 0),
  frequency TEXT DEFAULT 'MONTHLY' CHECK (frequency IN ('MONTHLY', 'WEEKLY', 'QUARTERLY', 'ANNUAL')),
  typical_due_day INT CHECK (typical_due_day >= 1 AND typical_due_day <= 31),
  is_confirmed BOOLEAN DEFAULT TRUE,
  is_active BOOLEAN DEFAULT TRUE,
  last_paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT uq_user_merchant_commitment UNIQUE (user_id, merchant_name)
);

CREATE INDEX IF NOT EXISTS idx_user_recurring_commitments_user
  ON public.user_recurring_commitments(user_id, is_active);

-- Enable Row Level Security
ALTER TABLE public.user_recurring_commitments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own recurring commitments"
  ON public.user_recurring_commitments
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own recurring commitments"
  ON public.user_recurring_commitments
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own recurring commitments"
  ON public.user_recurring_commitments
  FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own recurring commitments"
  ON public.user_recurring_commitments
  FOR DELETE
  USING (auth.uid() = user_id);

GRANT ALL ON TABLE public.user_recurring_commitments TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. AUTO-SYNC DETECTED BILLS INTO RECURRING COMMITMENTS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_detected_recurring_commitments(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  r RECORD;
  v_count INT := 0;
BEGIN
  IF auth.role() = 'authenticated' AND auth.uid() IS NOT NULL THEN
    v_uid := auth.uid();
  END IF;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  FOR r IN
    SELECT 
      COALESCE(clean_merchant_name, narration) AS merchant,
      ROUND(AVG(amount), 2) AS avg_amount,
      COALESCE(MAX(category), 'Subscription') AS cat,
      EXTRACT(DAY FROM MAX(transaction_timestamp AT TIME ZONE 'Asia/Kolkata'))::INT AS due_day,
      MAX(transaction_timestamp) AS last_txn
    FROM public.bank_transactions
    WHERE user_id = v_uid 
      AND (is_recurring = TRUE OR spend_tier = 'FIXED')
      AND UPPER(type) = 'DEBIT'
      AND COALESCE(clean_merchant_name, narration) IS NOT NULL
    GROUP BY COALESCE(clean_merchant_name, narration)
  LOOP
    INSERT INTO public.user_recurring_commitments (
      user_id,
      merchant_name,
      category,
      expected_amount,
      frequency,
      typical_due_day,
      is_confirmed,
      is_active,
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
$$;

GRANT EXECUTE ON FUNCTION public.sync_detected_recurring_commitments(UUID) TO service_role, authenticated;

-- -----------------------------------------------------------------------------
-- 3. THE FINANCIAL PATTERN ENGINE: get_cashflow_rhythm
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_cashflow_rhythm(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  -- Strict Production Security Check:
  -- Authenticated callers can only access their own user records
  IF auth.role() = 'authenticated' AND auth.uid() IS NOT NULL THEN
    v_uid := auth.uid();
  END IF;

  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  -- Auto-sync any newly detected bills from recent bank syncs
  SELECT public.sync_detected_recurring_commitments(v_uid) INTO v_dummy;

  -- 1. Fetch User Profile
  SELECT income_type, COALESCE(expected_monthly_income, 0.0)
  INTO v_income_type, v_expected_income
  FROM public.profiles
  WHERE id = v_uid;
  v_income_type := COALESCE(v_income_type, 'Salaried');

  -- 2. Determine Balance and Live/Historical Anchor Date
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

  -- 3. Inflow Fingerprinting & Cycle Resolution
  IF v_income_type = 'Salaried' OR v_income_type = 'Allowance' THEN
    -- Look for historical large credit entries to find recurring pay day
    SELECT EXTRACT(DAY FROM transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::INT
    INTO v_detected_payday
    FROM public.bank_transactions
    WHERE user_id = v_uid 
      AND UPPER(type) = 'CREDIT'
      AND (v_expected_income <= 0 OR amount >= (v_expected_income * 0.5))
    GROUP BY EXTRACT(DAY FROM transaction_timestamp AT TIME ZONE 'Asia/Kolkata')
    ORDER BY COUNT(*) DESC, MAX(transaction_timestamp) DESC
    LIMIT 1;

    -- Default to 1st of month if no credit pattern found yet
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
    -- Freelancer / Contractor / Self-Employed:
    -- Non-anchor cycle: Uses rolling 30-day projection to maintain a conservative floor
    v_next_income_date := (v_anchor::DATE + 30);
    v_days_to_next_inflow := 30;
  END IF;

  -- 4. Calculate Upcoming Committed Bills in this Window
  -- A bill is considered already paid in the current month if a debit matching merchant exists in last 28 days
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

  -- 5. Calculate Discretionary Spending Today & This Week
  -- Spent Today (from midnight of anchor date)
  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_spent_today
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND is_recurring = FALSE
    AND transaction_timestamp >= DATE_TRUNC('day', v_anchor)
    AND transaction_timestamp <= v_anchor;

  -- Spent This Week (from Monday of current week)
  SELECT COALESCE(SUM(amount), 0.0)
  INTO v_spent_this_week
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND is_recurring = FALSE
    AND transaction_timestamp >= DATE_TRUNC('week', v_anchor)
    AND transaction_timestamp <= v_anchor;

  -- Days left in the current week (Sunday = 0 in some calendars; ISO week Monday=1 to Sunday=7)
  -- EXTRACT(ISODOW FROM v_anchor): Monday is 1, Sunday is 7
  v_days_left_in_week := GREATEST(1, (7 - EXTRACT(ISODOW FROM v_anchor)::INT + 1));

  -- 6. Discretionary Safe Pool Calculation
  -- Safe Pool = Current Balance - Upcoming Bills
  v_safe_pool := GREATEST(0.0, v_balance - v_upcoming_bills_total);

  -- Safe-to-Spend Weekly:
  -- Scale the remaining safe pool over the remaining days in the cycle, then proportion for this week
  IF v_days_to_next_inflow > 0 THEN
    v_safe_week := ROUND((v_safe_pool / v_days_to_next_inflow) * v_days_left_in_week, 2);
  ELSE
    v_safe_week := ROUND(v_safe_pool, 2);
  END IF;

  -- Safe-to-Spend Daily (Today):
  -- Weekly allowance divided by days left in week
  IF v_days_left_in_week > 0 THEN
    v_safe_today := ROUND(GREATEST(0.0, (v_safe_week / v_days_left_in_week) - v_spent_today), 2);
  ELSE
    v_safe_today := ROUND(GREATEST(0.0, v_safe_week - v_spent_today), 2);
  END IF;

  -- Adjust Weekly remaining after subtracting this week's spent
  v_safe_week := ROUND(GREATEST(0.0, v_safe_week - v_spent_this_week), 2);

  -- 7. Daily Burn Velocity & Runway
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

  -- 8. Health Status determination
  IF v_balance < v_upcoming_bills_total THEN
    v_health_status := 'DEFICIT';
  ELSIF v_safe_today < 200 AND v_safe_pool < 2000 THEN
    v_health_status := 'CAUTION';
  ELSE
    v_health_status := 'HEALTHY';
  END IF;

  RETURN jsonb_build_object(
    'safe_to_spend_today', v_safe_today,
    'safe_to_spend_this_week', v_safe_week,
    'spent_today', ROUND(v_spent_today, 2),
    'spent_this_week', ROUND(v_spent_this_week, 2),
    'current_balance', ROUND(v_balance, 2),
    'upcoming_bills_total', ROUND(v_upcoming_bills_total, 2),
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
$$;

GRANT EXECUTE ON FUNCTION public.get_cashflow_rhythm(UUID) TO service_role, authenticated;
