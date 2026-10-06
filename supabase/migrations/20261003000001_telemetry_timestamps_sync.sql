-- =============================================================================
-- Migration: 20261003000001_telemetry_timestamps_sync.sql
-- Description: Ground Telemetry & Analytics calculations with transaction_timestamp and created_at
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. UPDATE get_telemetry_metrics RPC
-- -----------------------------------------------------------------------------
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
  v_last_ingested TIMESTAMPTZ;
  v_target_month TIMESTAMPTZ;
  v_type_filter TEXT := NULL;
  v_is_live BOOLEAN := FALSE;
  v_period_label TEXT := 'All Time';
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  -- 1. Get user transaction boundaries using transaction_timestamp and created_at
  SELECT 
    MIN(transaction_timestamp), 
    MAX(transaction_timestamp),
    MAX(CASE WHEN UPPER(type) = 'DEBIT' THEN transaction_timestamp ELSE NULL END),
    MAX(created_at)
  INTO v_earliest_txn, v_latest_txn, v_latest_debit, v_last_ingested
  FROM public.bank_transactions
  WHERE user_id = v_uid;

  -- 2. Recency determination: True if latest transaction occurred within last 7 days of real-world now
  v_is_live := (v_latest_txn IS NOT NULL AND (v_now - (v_latest_txn AT TIME ZONE 'Asia/Kolkata')) <= INTERVAL '7 days');

  -- 3. Determine date filtering window & type filter based on transaction_timestamp
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
    -- 'all'
    IF v_earliest_txn IS NOT NULL AND v_latest_txn IS NOT NULL THEN
      v_period_days := GREATEST(1, ROUND(EXTRACT(EPOCH FROM (v_latest_txn - v_earliest_txn)) / 86400)::INT);
      v_period_label := TO_CHAR(v_earliest_txn, 'DD Mon YYYY') || ' - ' || TO_CHAR(v_latest_txn, 'DD Mon YYYY');
    ELSE
      v_period_days := 30;
      v_period_label := 'All Time';
    END IF;
  END IF;

  -- 4. Calculate Inflow (CREDIT) and Outflow (DEBIT) using transaction_timestamp
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

  -- 5. Ratios
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

  -- 6. Dynamic Health Score (0-100)
  v_health_score := ROUND(LEAST(100.0, GREATEST(0.0, 50.0 + (v_savings_ratio * 30.0) - (v_disc_ratio * 20.0))))::INT;

  -- 7. Channel distribution by transaction_timestamp
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

  -- 8. Determine active month for weekly outflow velocity
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

  -- 9. Weekly outflow velocity (Weeks 1 to 4 of active month) based on transaction_timestamp
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
    'weekly_outflow_velocity', v_weekly_outflow,
    'latest_transaction_timestamp', TO_CHAR(v_latest_txn, 'YYYY-MM-DD HH24:MI:SS'),
    'last_synced_at', TO_CHAR(v_last_ingested, 'YYYY-MM-DD HH24:MI:SS'),
    'is_live', v_is_live,
    'statement_period_label', v_period_label
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_telemetry_metrics(UUID, TEXT) TO service_role, authenticated;

-- -----------------------------------------------------------------------------
-- 2. UPDATE user_financial_snapshot VIEW
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.user_financial_snapshot AS
WITH latest_txns AS (
  SELECT 
    user_id,
    MAX(transaction_timestamp) as latest_ts,
    MIN(transaction_timestamp) as earliest_ts,
    MAX(created_at) as latest_created_at
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
    WHEN lt.latest_ts IS NULL THEN 'No recent records'
    WHEN (NOW() - lt.latest_ts) <= INTERVAL '7 days' THEN 'this week'
    ELSE TO_CHAR(lt.latest_ts - INTERVAL '7 days', 'DD Mon') || ' - ' || TO_CHAR(lt.latest_ts, 'DD Mon YYYY')
  END AS statement_period_label,
  lt.latest_ts AS latest_transaction_timestamp,
  lt.latest_created_at AS latest_created_at
FROM auth.users u
LEFT JOIN latest_txns lt ON lt.user_id = u.id
LEFT JOIN latest_balance lb ON lb.user_id = u.id
LEFT JOIN agg_7d a7 ON a7.user_id = u.id
LEFT JOIN top_cat tc ON tc.user_id = u.id
LEFT JOIN recurring_cnt rc ON rc.user_id = u.id;

GRANT SELECT ON public.user_financial_snapshot TO authenticated, service_role;
