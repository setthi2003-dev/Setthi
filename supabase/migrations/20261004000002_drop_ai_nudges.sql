-- =============================================================================
-- Migration: 20261004000002_drop_ai_nudges.sql
-- Description: Drop public.ai_nudges table and update delete_user_account RPC
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- 1. Update delete_user_account RPC to remove reference to ai_nudges
CREATE OR REPLACE FUNCTION public.delete_user_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $function$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- 1. Purge financial transactions belonging to user
  DELETE FROM public.bank_transactions WHERE user_id = v_uid;

  -- 2. Purge bank accounts belonging to user
  DELETE FROM public.bank_accounts WHERE user_id = v_uid;

  -- 3. Purge account aggregator consents belonging to user
  DELETE FROM public.aa_consents WHERE user_id = v_uid;

  -- 4. Purge chat history belonging to user
  DELETE FROM public.chat_messages WHERE user_id = v_uid;

  -- 5. Purge user profile in public schema
  DELETE FROM public.profiles WHERE id = v_uid;

  -- 6. Permanently delete user from auth.users (cascades sessions, identities, tokens)
  DELETE FROM auth.users WHERE id = v_uid;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated;

-- 2. Drop ai_nudges table and its indexes/policies
DROP TABLE IF EXISTS public.ai_nudges CASCADE;
