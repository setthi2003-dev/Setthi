-- Migration: Category Breakdown RPC & Chat Sessions (Phase 5)
-- Description:
-- 1. get_category_breakdown: Deterministic breakdown of shop/service spending grouped by all categories.
-- 2. chat_messages.session_id: Supports multi-turn conversational threading and session segmentation.

-- 1. Session Column on chat_messages
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS session_id UUID;
CREATE INDEX IF NOT EXISTS idx_chat_messages_session ON public.chat_messages(user_id, session_id);

-- 2. get_category_breakdown RPC
CREATE OR REPLACE FUNCTION public.get_category_breakdown(
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid;
  v_stmt_start date;
  v_stmt_end date;
  v_eff_start date;
  v_eff_end date;
  v_grand_total numeric := 0.0;
  v_shop_total numeric := 0.0;
  v_bank_charges numeric := 0.0;
  v_transfers numeric := 0.0;
  v_categories jsonb := '[]'::jsonb;
BEGIN
  v_uid := CASE 
      WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
      WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
      ELSE auth.uid()
  END;

  IF v_uid IS NULL THEN
      RETURN jsonb_build_object('error', 'Unauthorized');
  END IF;

  SELECT 
      MIN((transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date),
      MAX((transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date)
  INTO v_stmt_start, v_stmt_end
  FROM public.bank_transactions
  WHERE user_id = v_uid;

  v_eff_start := coalesce(p_start_date, v_stmt_start);
  v_eff_end := coalesce(p_end_date, v_stmt_end);

  -- Grand total of all debits (money out)
  SELECT coalesce(SUM(amount), 0.0)
  INTO v_grand_total
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND (p_start_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_start_date)
    AND (p_end_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_end_date);

  -- Subtotals
  SELECT 
    coalesce(SUM(CASE WHEN txn_kind = 'SPEND' THEN amount ELSE 0 END), 0.0),
    coalesce(SUM(CASE WHEN txn_kind = 'BANK_FEE' THEN amount ELSE 0 END), 0.0),
    coalesce(SUM(CASE WHEN txn_kind = 'PERSON_OUT' THEN amount ELSE 0 END), 0.0)
  INTO v_shop_total, v_bank_charges, v_transfers
  FROM public.bank_transactions
  WHERE user_id = v_uid
    AND UPPER(type) = 'DEBIT'
    AND (p_start_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_start_date)
    AND (p_end_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_end_date);

  -- Group by resolved category across all debits
  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'category', cat,
      'txn_kind', max_kind,
      'amount', ROUND(cat_amount, 2),
      'count', cat_count,
      'percentage', CASE 
        WHEN v_grand_total > 0 THEN ROUND((cat_amount / v_grand_total) * 100.0, 1)
        ELSE 0.0 
      END
    ) ORDER BY cat_amount DESC
  ), '[]'::jsonb)
  INTO v_categories
  FROM (
    SELECT 
      CASE 
        WHEN txn_kind = 'BANK_FEE' THEN 'Bank charges'
        WHEN txn_kind = 'PERSON_OUT' THEN 'Transfers to people'
        ELSE coalesce(nullif(trim(habit_category), ''), nullif(trim(category), ''), 'General')
      END AS cat,
      MAX(txn_kind) AS max_kind,
      SUM(amount) AS cat_amount,
      COUNT(*) AS cat_count
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'DEBIT'
      AND (p_start_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_start_date)
      AND (p_end_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_end_date)
    GROUP BY 
      CASE 
        WHEN txn_kind = 'BANK_FEE' THEN 'Bank charges'
        WHEN txn_kind = 'PERSON_OUT' THEN 'Transfers to people'
        ELSE coalesce(nullif(trim(habit_category), ''), nullif(trim(category), ''), 'General')
      END
  ) sub;

  RETURN jsonb_build_object(
    'period_start', v_eff_start::text,
    'period_end', v_eff_end::text,
    'grand_total_money_out', ROUND(v_grand_total, 2),
    'shop_spend_total', ROUND(v_shop_total, 2),
    'bank_charges_total', ROUND(v_bank_charges, 2),
    'transfers_total', ROUND(v_transfers, 2),
    'category_count', jsonb_array_length(v_categories),
    'categories', v_categories
  );
END;
$$;
