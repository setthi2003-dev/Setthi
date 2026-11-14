-- Fix post_import_pipeline balance null constraint bug
-- When syncing credit card transactions (e.g. from Gmail or receipts), verified savings statement balance is null.
-- Previously, updating current_balance with null caused a not-null constraint violation on bank_accounts.

CREATE OR REPLACE FUNCTION public.post_import_pipeline(p_user_id uuid DEFAULT auth.uid())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_uid uuid;
    v_bal_res jsonb;
    v_bal_amt numeric;
BEGIN
    v_uid := CASE 
        WHEN current_user IN ('postgres', 'service_role') OR auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
        ELSE auth.uid()
    END;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    -- 1. tag_transactions (behavioral tagging engine)
    PERFORM public.tag_transactions(v_uid);

    -- 2. recurring detection/sync
    PERFORM public.sync_detected_recurring_commitments(v_uid);

    -- 3. classify_transactions (spend_tier & is_recurring)
    PERFORM public.classify_transactions(v_uid);

    -- 4. bank_accounts balance update (only update if verified statement balance exists)
    v_bal_res := public.get_balance_facts(v_uid);
    IF (v_bal_res->>'verified')::boolean IS TRUE AND (v_bal_res->>'amount') IS NOT NULL THEN
        v_bal_amt := (v_bal_res->>'amount')::numeric;
        UPDATE public.bank_accounts
        SET current_balance = v_bal_amt,
            updated_at = now()
        WHERE user_id = v_uid
          AND fip_id = 'STATEMENT_IMPORT';
    END IF;

    -- 5. refresh_habit_profile
    PERFORM public.refresh_habit_profile(v_uid);

    RETURN jsonb_build_object(
        'success', true,
        'user_id', v_uid,
        'balance', v_bal_amt,
        'verified', coalesce((v_bal_res->>'verified')::boolean, false)
    );
END;
$function$;
