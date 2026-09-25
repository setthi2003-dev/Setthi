-- =============================================================================
-- Migration: 20260924000000_ai_telemetry_and_intelligence.sql
-- Description: AI Intelligent Layer, Spend Tiers, Habit Detector, Snapshot View & Telemetry RPCs
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. EXTEND public.bank_transactions WITH SPEND TIERS & RECURRING FLAGS
-- -----------------------------------------------------------------------------
ALTER TABLE public.bank_transactions
  ADD COLUMN IF NOT EXISTS spend_tier TEXT CHECK (spend_tier IN ('FIXED', 'ESSENTIAL', 'IMPULSE', 'GENERAL')) DEFAULT 'GENERAL',
  ADD COLUMN IF NOT EXISTS is_recurring BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_bank_transactions_tier 
  ON public.bank_transactions(user_id, spend_tier);

CREATE INDEX IF NOT EXISTS idx_bank_transactions_recurring 
  ON public.bank_transactions(user_id, is_recurring);

-- -----------------------------------------------------------------------------
-- 2. HABIT DETECTOR & CLASSIFICATION PROCEDURE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.classify_transactions(p_user_id UUID DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1. FIXED & is_recurring = TRUE
  -- Matches Netflix, Spotify, Apple, Google Play, Cult.fit, Prime, mobile recharges, rent, broadband
  UPDATE public.bank_transactions
  SET 
    spend_tier = 'FIXED',
    is_recurring = TRUE
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND UPPER(type) = 'DEBIT'
    AND (
      clean_merchant_name ~* '(netflix|spotify|apple|google play|cult\.fit|cultfit|prime|amazon prime|hotstar|youtube premium|airtel|jio|vi |vodafone|rent|broadband|wifi|act fibernet|tata play)'
      OR narration ~* '(netflix|spotify|apple\.com|google.*play|cult\.fit|cultfit|prime video|hotstar|youtube.*prem|airtel|jio.*recharge|rent|broadband|actcorp|tatasky|tataplay)'
      OR category ILIKE '%subscription%'
      OR category ILIKE '%rent%'
      OR category ILIKE '%telecom%'
    );

  -- 2. IMPULSE
  -- Food delivery or quick-commerce debit (Swiggy, Zomato, Zepto, Blinkit, Instamart) occurring between 11:00 PM and 04:00 AM IST,
  -- OR transactions with amount under ₹300 tagged as dining/quick-commerce/food delivery.
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
  -- Groceries, utilities, fuel, public transport, electricity, medical
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
  -- All remaining
  UPDATE public.bank_transactions
  SET spend_tier = 'GENERAL'
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
    AND spend_tier NOT IN ('FIXED', 'IMPULSE', 'ESSENTIAL');

END;
$$;

GRANT EXECUTE ON FUNCTION public.classify_transactions(UUID) TO service_role, authenticated;

-- Backfill existing records
SELECT public.classify_transactions(NULL);

-- -----------------------------------------------------------------------------
-- 3. TABLE public.ai_nudges
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_nudges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  headline TEXT NOT NULL,
  body TEXT NOT NULL,
  badge_text TEXT NOT NULL DEFAULT 'INSIGHT',
  card_style TEXT NOT NULL DEFAULT 'heroPastel2' CHECK (card_style IN ('heroPastel1', 'heroPastel2', 'heroPastel3', 'heroPastel4')),
  action_label TEXT,
  metric_tag TEXT,
  is_dismissed BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_nudges_user_active 
  ON public.ai_nudges(user_id, created_at DESC) 
  WHERE is_dismissed = FALSE;

ALTER TABLE public.ai_nudges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can manage their own nudges" ON public.ai_nudges;
CREATE POLICY "Users can manage their own nudges" ON public.ai_nudges
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role full access on ai_nudges" ON public.ai_nudges;
CREATE POLICY "Service role full access on ai_nudges" ON public.ai_nudges
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 4. FAST SNAPSHOT VIEW: public.user_financial_snapshot
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.user_financial_snapshot AS
WITH latest_txns AS (
  SELECT 
    user_id,
    MAX(transaction_timestamp) as latest_ts,
    MIN(transaction_timestamp) as earliest_ts
  FROM public.bank_transactions
  GROUP BY user_id
),
latest_balance AS (
  SELECT DISTINCT ON (user_id)
    user_id,
    current_balance
  FROM public.bank_transactions
  WHERE current_balance IS NOT NULL
  ORDER BY user_id, transaction_timestamp DESC, created_at DESC
),
agg_7d AS (
  SELECT
    bt.user_id,
    SUM(CASE WHEN UPPER(bt.type) = 'DEBIT' THEN bt.amount ELSE 0 END) AS spent_last_7d,
    SUM(CASE WHEN UPPER(bt.type) = 'CREDIT' THEN bt.amount ELSE 0 END) AS inflow_last_7d,
    SUM(CASE WHEN UPPER(bt.type) = 'DEBIT' AND bt.spend_tier = 'IMPULSE' THEN bt.amount ELSE 0 END) AS impulse_last_7d
  FROM public.bank_transactions bt
  JOIN latest_txns lt ON lt.user_id = bt.user_id
  WHERE bt.transaction_timestamp >= (
    CASE 
      WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN (NOW() - INTERVAL '7 days')
      ELSE (lt.latest_ts - INTERVAL '7 days')
    END
  )
  AND bt.transaction_timestamp <= (
    CASE 
      WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN NOW()
      ELSE lt.latest_ts
    END
  )
  GROUP BY bt.user_id
),
top_cat AS (
  SELECT DISTINCT ON (bt.user_id)
    bt.user_id,
    COALESCE(bt.category, 'General') AS top_category_7d
  FROM public.bank_transactions bt
  JOIN latest_txns lt ON lt.user_id = bt.user_id
  WHERE UPPER(bt.type) = 'DEBIT'
    AND bt.transaction_timestamp >= (
      CASE 
        WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN (NOW() - INTERVAL '7 days')
        ELSE (lt.latest_ts - INTERVAL '7 days')
      END
    )
    AND bt.transaction_timestamp <= (
      CASE 
        WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN NOW()
        ELSE lt.latest_ts
      END
    )
  GROUP BY bt.user_id, COALESCE(bt.category, 'General')
  ORDER BY bt.user_id, SUM(bt.amount) DESC
),
recurring_cnt AS (
  SELECT
    user_id,
    COUNT(DISTINCT COALESCE(clean_merchant_name, narration)) AS active_recurring_count
  FROM public.bank_transactions
  WHERE is_recurring = TRUE AND UPPER(type) = 'DEBIT'
  GROUP BY user_id
)
SELECT
  u.id AS user_id,
  COALESCE(lb.current_balance, 0.0) AS current_balance,
  ROUND(COALESCE(a7.spent_last_7d, 0.0), 2) AS spent_last_7d,
  ROUND(COALESCE(a7.inflow_last_7d, 0.0), 2) AS inflow_last_7d,
  COALESCE(tc.top_category_7d, 'None') AS top_category_7d,
  CASE 
    WHEN COALESCE(a7.spent_last_7d, 0.0) > 0 
    THEN ROUND((COALESCE(a7.impulse_last_7d, 0.0) / a7.spent_last_7d * 100), 1)
    ELSE 0.0
  END AS impulse_ratio_7d,
  COALESCE(rc.active_recurring_count, 0)::INT AS active_recurring_count,
  ROUND(GREATEST(0.0, COALESCE(lb.current_balance, 0.0) / 30.0), 2) AS safe_to_spend_daily,
  CASE 
    WHEN lt.latest_ts IS NOT NULL AND (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN TRUE
    ELSE FALSE
  END AS is_live_data,
  CASE 
    WHEN lt.latest_ts IS NULL THEN 'No data'
    WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN 'this week'
    ELSE TO_CHAR(lt.latest_ts - INTERVAL '7 days', 'DD Mon') || ' - ' || TO_CHAR(lt.latest_ts, 'DD Mon YYYY')
  END AS statement_period_label
FROM auth.users u
LEFT JOIN latest_txns lt ON lt.user_id = u.id
LEFT JOIN latest_balance lb ON lb.user_id = u.id
LEFT JOIN agg_7d a7 ON a7.user_id = u.id
LEFT JOIN top_cat tc ON tc.user_id = u.id
LEFT JOIN recurring_cnt rc ON rc.user_id = u.id;

GRANT SELECT ON public.user_financial_snapshot TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. DETERMINISTIC FINANCIAL RPC TOOLS
-- -----------------------------------------------------------------------------

-- 5.1 get_safe_to_spend
CREATE OR REPLACE FUNCTION public.get_safe_to_spend(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.get_safe_to_spend(UUID) TO service_role, authenticated;

-- 5.2 detect_recurring_costs
CREATE OR REPLACE FUNCTION public.detect_recurring_costs(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := COALESCE(p_user_id, auth.uid());
  v_total NUMERIC := 0.0;
  v_subs JSONB := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT 
    COALESCE(SUM(sub.amount), 0.0),
    COALESCE(jsonb_agg(sub), '[]'::jsonb)
  INTO v_total, v_subs
  FROM (
    SELECT 
      COALESCE(clean_merchant_name, narration) AS merchant,
      ROUND(AVG(amount), 2) AS amount,
      TO_CHAR(MAX(transaction_timestamp), 'YYYY-MM-DD') AS last_date,
      COALESCE(MAX(category), 'Subscription') AS category
    FROM public.bank_transactions
    WHERE user_id = v_uid 
      AND (is_recurring = TRUE OR spend_tier = 'FIXED')
      AND UPPER(type) = 'DEBIT'
    GROUP BY COALESCE(clean_merchant_name, narration)
    ORDER BY amount DESC
  ) sub;

  RETURN jsonb_build_object(
    'total_monthly_recurring', ROUND(v_total, 2),
    'subscriptions', v_subs
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.detect_recurring_costs(UUID) TO service_role, authenticated;

-- 5.3 get_cashflow_velocity
CREATE OR REPLACE FUNCTION public.get_cashflow_velocity(
  p_user_id UUID DEFAULT auth.uid(),
  p_days INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

GRANT EXECUTE ON FUNCTION public.get_cashflow_velocity(UUID, INT) TO service_role, authenticated;

-- 5.4 get_telemetry_metrics
CREATE OR REPLACE FUNCTION public.get_telemetry_metrics(
  p_user_id UUID DEFAULT auth.uid(),
  p_period TEXT DEFAULT 'all'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_weekly_outflow JSONB := '[]'::jsonb;
  v_earliest_txn TIMESTAMPTZ;
  v_latest_txn TIMESTAMPTZ;
  v_latest_debit TIMESTAMPTZ;
  v_target_month TIMESTAMPTZ;
  v_type_filter TEXT := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  -- Get user transaction boundaries
  SELECT 
    MIN(transaction_timestamp), 
    MAX(transaction_timestamp),
    MAX(CASE WHEN UPPER(type) = 'DEBIT' THEN transaction_timestamp ELSE NULL END)
  INTO v_earliest_txn, v_latest_txn, v_latest_debit
  FROM public.bank_transactions
  WHERE user_id = v_uid;

  -- Determine date filtering window & type filter
  IF p_period = 'month' THEN
    -- If current month has transactions, use current month; else use latest active month
    IF EXISTS (SELECT 1 FROM public.bank_transactions WHERE user_id = v_uid AND transaction_timestamp >= v_month_start) THEN
      v_start_time := v_month_start;
      v_period_days := GREATEST(1, EXTRACT(DAY FROM v_now)::INT);
    ELSIF v_latest_txn IS NOT NULL THEN
      v_start_time := DATE_TRUNC('month', v_latest_txn AT TIME ZONE 'Asia/Kolkata');
      v_end_time := v_start_time + INTERVAL '1 month';
      v_period_days := GREATEST(1, EXTRACT(DAY FROM (v_latest_txn - v_start_time))::INT);
    ELSE
      v_start_time := v_month_start;
      v_period_days := 30;
    END IF;
  ELSIF p_period = '7d' THEN
    -- If transactions in last 7 days exist, use them; else use latest 7 active days
    IF EXISTS (SELECT 1 FROM public.bank_transactions WHERE user_id = v_uid AND transaction_timestamp >= NOW() - INTERVAL '7 days') THEN
      v_start_time := NOW() - INTERVAL '7 days';
    ELSIF v_latest_txn IS NOT NULL THEN
      v_start_time := v_latest_txn - INTERVAL '7 days';
      v_end_time := v_latest_txn + INTERVAL '1 second';
    ELSE
      v_start_time := NOW() - INTERVAL '7 days';
    END IF;
    v_period_days := 7;
  ELSIF p_period = 'debits' THEN
    v_type_filter := 'DEBIT';
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
    ELSE
      v_period_days := 30;
    END IF;
  ELSIF p_period = 'inflow' THEN
    v_type_filter := 'CREDIT';
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
    ELSE
      v_period_days := 30;
    END IF;
  ELSE
    -- 'all'
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
    ELSE
      v_period_days := 30;
    END IF;
  END IF;

  -- Inflow (CREDIT) and Outflow (DEBIT)
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

  -- Ratios
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

  -- Dynamic Health Score: 0-100
  -- Baseline 50 + (savings_ratio * 30) - (discretionary_ratio * 20)
  v_health_score := ROUND(LEAST(100.0, GREATEST(0.0, 50.0 + (v_savings_ratio * 30.0) - (v_disc_ratio * 20.0))))::INT;

  -- Channel distribution (UPI, ATM, CARD, FT, etc.)
  -- Percentage volume is calculated as percentage of monetary volume
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

  -- Determine active month for weekly outflow velocity
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

  -- Weekly outflow velocity (Weeks 1 to 4 of active month)
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
    'weekly_outflow_velocity', v_weekly_outflow
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_telemetry_metrics(UUID, TEXT) TO service_role, authenticated;

