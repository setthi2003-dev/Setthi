-- =============================================================================
-- Migration: 20260922000000_setthi_ai_credits_chat_rpcs.sql
-- Description: Setthi AI Financial Chat Companion - Credits, History & RPCs
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- 1. USER PROFILE CREDITS
-- Add ai_credits to public.profiles with default of 3
ALTER TABLE public.profiles 
  ADD COLUMN IF NOT EXISTS ai_credits INT NOT NULL DEFAULT 3 CHECK (ai_credits >= 0);

-- Set 3 credits for any existing profiles where it might be null
UPDATE public.profiles 
  SET ai_credits = 3 
  WHERE ai_credits IS NULL;

-- Update or create handle_new_user trigger function to grant 3 free credits upon signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER 
LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, avatar_url, ai_credits, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', ''),
    NEW.raw_user_meta_data->>'avatar_url',
    3,
    NOW()
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = CASE 
      WHEN EXCLUDED.full_name IS NOT NULL AND EXCLUDED.full_name <> '' 
      THEN EXCLUDED.full_name 
      ELSE profiles.full_name 
    END,
    avatar_url = COALESCE(EXCLUDED.avatar_url, profiles.avatar_url),
    ai_credits = COALESCE(profiles.ai_credits, 3),
    updated_at = NOW();

  RETURN NEW;
END;
$$;

-- Ensure trigger exists on auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 2. ATOMIC CREDIT DEDUCTION RPC
-- Atomically decrements 1 credit if balance > 0, returns TRUE if deducted, FALSE if insufficient
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.deduct_ai_credit(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated INT;
BEGIN
  UPDATE public.profiles
  SET ai_credits = ai_credits - 1
  WHERE id = p_user_id AND ai_credits > 0;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.deduct_ai_credit(UUID) TO service_role, authenticated;

-- -----------------------------------------------------------------------------
-- 3. CHAT HISTORY PERSISTENCE (public.chat_messages)
-- Stores conversation turns between user and Setthi AI
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content TEXT NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Efficient indexing for chronological query lookups
CREATE INDEX IF NOT EXISTS idx_chat_messages_user_date 
  ON public.chat_messages(user_id, created_at DESC);

-- Enable RLS
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- RLS: Authenticated users can view their own messages
DROP POLICY IF EXISTS "Users can select their own chat messages" ON public.chat_messages;
CREATE POLICY "Users can select their own chat messages"
  ON public.chat_messages FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- RLS: Authenticated users can insert their own messages
DROP POLICY IF EXISTS "Users can insert their own chat messages" ON public.chat_messages;
CREATE POLICY "Users can insert their own chat messages"
  ON public.chat_messages FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Service role full access
DROP POLICY IF EXISTS "Service role has full access to chat messages" ON public.chat_messages;
CREATE POLICY "Service role has full access to chat messages"
  ON public.chat_messages FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- 4. DETERMINISTIC FINANCIAL RPC TOOLS FOR GEMINI FUNCTION CALLING
-- -----------------------------------------------------------------------------

-- 4.1. get_current_balance
-- Returns the latest bank account balance and as-of date
CREATE OR REPLACE FUNCTION public.get_current_balance(p_user_id UUID DEFAULT auth.uid())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
  v_as_of TIMESTAMPTZ;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  -- 1. Try finding latest transaction balance
  SELECT current_balance, transaction_timestamp
  INTO v_balance, v_as_of
  FROM public.bank_transactions
  WHERE user_id = p_user_id AND current_balance IS NOT NULL
  ORDER BY transaction_timestamp DESC, created_at DESC
  LIMIT 1;

  -- 2. Fallback to bank_accounts summary balance if no transactions exist yet
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
$$;

GRANT EXECUTE ON FUNCTION public.get_current_balance(UUID) TO service_role, authenticated;

-- 4.2. get_spending_summary
-- Calculates total spending, count, and top transactions for a category/merchant/date range
CREATE OR REPLACE FUNCTION public.get_spending_summary(
  p_category TEXT DEFAULT NULL,
  p_merchant TEXT DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total NUMERIC := 0.0;
  v_count INT := 0;
  v_top_txns JSONB := '[]'::jsonb;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('error', 'User not authenticated');
  END IF;

  -- Compute aggregated sum & count for DEBITS
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

  -- Fetch top 3 debit transactions in this criteria
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
$$;

GRANT EXECUTE ON FUNCTION public.get_spending_summary(TEXT, TEXT, DATE, DATE, UUID) TO service_role, authenticated;

-- 4.3. list_recent_transactions
-- Returns last N transactions (max 5) cleanly formatted
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
