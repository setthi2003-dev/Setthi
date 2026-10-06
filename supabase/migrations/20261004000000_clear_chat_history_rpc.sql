-- =============================================================================
-- Migration: 20261004000000_clear_chat_history_rpc.sql
-- Description: Allow users to delete their chat history from backend & RPC
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

-- 1. Enable DELETE policy on public.chat_messages for authenticated users
DROP POLICY IF EXISTS "Users can delete their own chat messages" ON public.chat_messages;
CREATE POLICY "Users can delete their own chat messages"
  ON public.chat_messages FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);

-- 2. Create atomic clear_chat_history RPC
CREATE OR REPLACE FUNCTION public.clear_chat_history(p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_target_user UUID;
BEGIN
  v_target_user := COALESCE(p_user_id, auth.uid());
  IF v_target_user IS NULL THEN
    RETURN FALSE;
  END IF;

  -- Security check: authenticated users can only clear their own messages
  IF auth.role() = 'authenticated' AND auth.uid() <> v_target_user THEN
    RAISE EXCEPTION 'Unauthorized: cannot clear chat history for another user';
  END IF;

  DELETE FROM public.chat_messages
  WHERE user_id = v_target_user;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_chat_history(UUID) TO service_role, authenticated;
