-- Migration: 20260925000000_delete_user_account_rpc.sql
-- Description: Adds delete_user_account RPC function to allow authenticated users
-- to permanently delete their account and purge all associated financial data.

CREATE OR REPLACE FUNCTION public.delete_user_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 1. Explicitly purge application tables
  DELETE FROM public.bank_transactions WHERE user_id = v_uid;
  DELETE FROM public.user_custom_merchant_categories WHERE user_id = v_uid;
  DELETE FROM public.setu_consents WHERE user_id = v_uid;
  DELETE FROM public.ai_nudges WHERE user_id = v_uid;
  DELETE FROM public.ai_chat_messages WHERE user_id = v_uid;
  DELETE FROM public.profiles WHERE id = v_uid;

  -- 2. Delete user from auth.users (cascades remaining auth objects)
  DELETE FROM auth.users WHERE id = v_uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated;
