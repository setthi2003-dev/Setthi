-- =============================================================================
-- Migration: 20261009000000_ensure_complete_user_deletion_cascade.sql
-- Description: Enforce ON DELETE CASCADE on user_habit_profile and ensure
--              complete user data purge across all tables in delete_user_account RPC.
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- 1. Ensure foreign key constraint with ON DELETE CASCADE exists on user_habit_profile
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'public' AND table_name = 'user_habit_profile'
  ) THEN
    ALTER TABLE public.user_habit_profile
      DROP CONSTRAINT IF EXISTS user_habit_profile_user_id_fkey,
      ADD CONSTRAINT user_habit_profile_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
END $$;

-- 2. Update delete_user_account RPC function to guarantee all user tables are purged
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
    RAISE EXCEPTION 'Not authenticated: cannot delete account without active session';
  END IF;

  -- 1. Purge financial transactions belonging to user
  DELETE FROM public.bank_transactions WHERE user_id = v_uid;

  -- 2. Purge recurring commitments belonging to user
  DELETE FROM public.user_recurring_commitments WHERE user_id = v_uid;

  -- 3. Purge habit profiles and financial archetype belonging to user
  DELETE FROM public.user_habit_profile WHERE user_id = v_uid;

  -- 4. Purge bank accounts belonging to user
  DELETE FROM public.bank_accounts WHERE user_id = v_uid;

  -- 5. Purge account aggregator consents belonging to user
  DELETE FROM public.aa_consents WHERE user_id = v_uid;

  -- 6. Purge chat history belonging to user
  DELETE FROM public.chat_messages WHERE user_id = v_uid;

  -- 7. Purge AI telemetry nudges belonging to user (if table exists)
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'ai_nudges') THEN
    DELETE FROM public.ai_nudges WHERE user_id = v_uid;
  END IF;

  -- 8. Purge user profile in public schema
  DELETE FROM public.profiles WHERE id = v_uid;

  -- 9. Permanently delete user from auth.users (cascades sessions, identities, tokens, and any foreign keys)
  DELETE FROM auth.users WHERE id = v_uid;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'delete_user_account failed: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated;
