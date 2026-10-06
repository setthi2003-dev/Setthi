-- =============================================================================
-- Migration: 20261003000000_update_recent_transactions_timestamps.sql
-- Description: Expose transaction_timestamp and created_at in list_recent_transactions RPC
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

CREATE OR REPLACE FUNCTION public.list_recent_transactions(
  p_limit INT DEFAULT 5,
  p_flow_type TEXT DEFAULT NULL,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_effective_limit INT := LEAST(COALESCE(p_limit, 5), 5);
  v_result JSONB := '[]'::jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  SELECT jsonb_agg(sub)
  INTO v_result
  FROM (
    SELECT 
      clean_merchant_name AS merchant,
      ROUND(amount, 2) AS amount,
      UPPER(type) AS type,
      COALESCE(category, 'Uncategorized') AS category,
      TO_CHAR(transaction_timestamp, 'YYYY-MM-DD HH24:MI:SS') AS transaction_timestamp,
      TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at,
      TO_CHAR(transaction_timestamp, 'YYYY-MM-DD HH24:MI') AS date,
      mode
    FROM public.bank_transactions
    WHERE user_id = p_user_id
      AND (p_flow_type IS NULL OR UPPER(type) = UPPER(p_flow_type))
    ORDER BY transaction_timestamp DESC, created_at DESC
    LIMIT v_effective_limit
  ) sub;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_recent_transactions(INT, TEXT, UUID) TO service_role, authenticated;
