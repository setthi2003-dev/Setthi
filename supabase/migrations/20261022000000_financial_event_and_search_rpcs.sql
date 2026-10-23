-- Migration: Add resolve_financial_event and search_transactions RPCs for AI Agent
-- Description:
-- 1. resolve_financial_event: Resolves temporal anchor events (allowance, salary, stipend, parent transfer) to exact dates and counterparties.
-- 2. search_transactions: Allows natural-language search across merchants, counterparties, narrations, categories, and amounts.

-- 1. resolve_financial_event
CREATE OR REPLACE FUNCTION public.resolve_financial_event(
    p_event_type text,
    p_hint text DEFAULT NULL,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid uuid;
    v_rec record;
    v_recent_credits jsonb := '[]'::jsonb;
    v_stmt_end date;
BEGIN
    v_uid := CASE 
        WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
        WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
        ELSE auth.uid()
    END;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('error', 'Unauthorized');
    END IF;

    -- Get the latest transaction date for the user
    SELECT MAX((transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date)
    INTO v_stmt_end
    FROM public.bank_transactions
    WHERE user_id = v_uid;

    -- 1. Try matching with hint if provided
    IF p_hint IS NOT NULL AND length(trim(p_hint)) > 0 THEN
        SELECT 
            id,
            (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date AS txn_date,
            TO_CHAR(transaction_timestamp AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') AS txn_ts,
            amount,
            current_balance,
            clean_merchant_name,
            counterparty_key,
            narration,
            txn_kind
        INTO v_rec
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND UPPER(type) = 'CREDIT'
          AND (
              clean_merchant_name ILIKE '%' || p_hint || '%'
              OR narration ILIKE '%' || p_hint || '%'
              OR counterparty_key ILIKE '%' || p_hint || '%'
          )
        ORDER BY transaction_timestamp DESC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'found', true,
                'event_type', p_event_type,
                'match_reason', 'Matched search hint: ' || p_hint,
                'event_date', v_rec.txn_date::text,
                'event_timestamp', v_rec.txn_ts,
                'amount', ROUND(v_rec.amount, 2),
                'sender_or_merchant', coalesce(v_rec.clean_merchant_name, v_rec.counterparty_key, 'Unknown'),
                'narration', v_rec.narration,
                'balance_after', ROUND(v_rec.current_balance, 2),
                'confidence', 'HIGH',
                'suggested_start_date', v_rec.txn_date::text,
                'suggested_end_date', coalesce(v_stmt_end::text, v_rec.txn_date::text)
            );
        END IF;
    END IF;

    -- 2. Match by event type keyword in narration
    IF LOWER(p_event_type) IN ('salary', 'allowance', 'stipend', 'income', 'pocket_money', 'remittance') THEN
        SELECT 
            id,
            (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date AS txn_date,
            TO_CHAR(transaction_timestamp AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') AS txn_ts,
            amount,
            current_balance,
            clean_merchant_name,
            counterparty_key,
            narration,
            txn_kind
        INTO v_rec
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND UPPER(type) = 'CREDIT'
          AND (
              narration ~* '(salary|stipend|allowance|payroll|monthly|pocket money)'
              OR clean_merchant_name ~* '(salary|stipend|allowance)'
          )
        ORDER BY transaction_timestamp DESC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'found', true,
                'event_type', p_event_type,
                'match_reason', 'Matched keyword in narration',
                'event_date', v_rec.txn_date::text,
                'event_timestamp', v_rec.txn_ts,
                'amount', ROUND(v_rec.amount, 2),
                'sender_or_merchant', coalesce(v_rec.clean_merchant_name, v_rec.counterparty_key, 'Unknown'),
                'narration', v_rec.narration,
                'balance_after', ROUND(v_rec.current_balance, 2),
                'confidence', 'HIGH',
                'suggested_start_date', v_rec.txn_date::text,
                'suggested_end_date', coalesce(v_stmt_end::text, v_rec.txn_date::text)
            );
        END IF;

        -- Fallback: Look for significant inbound credits (>= 1000) or major transfers from individuals (family/parents)
        SELECT 
            id,
            (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date AS txn_date,
            TO_CHAR(transaction_timestamp AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') AS txn_ts,
            amount,
            current_balance,
            clean_merchant_name,
            counterparty_key,
            narration,
            txn_kind
        INTO v_rec
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND UPPER(type) = 'CREDIT'
          AND amount >= 1000
        ORDER BY transaction_timestamp DESC
        LIMIT 1;

        IF FOUND THEN
            RETURN jsonb_build_object(
                'found', true,
                'event_type', p_event_type,
                'match_reason', 'Largest/significant inbound transfer (>= 1,000)',
                'event_date', v_rec.txn_date::text,
                'event_timestamp', v_rec.txn_ts,
                'amount', ROUND(v_rec.amount, 2),
                'sender_or_merchant', coalesce(v_rec.clean_merchant_name, v_rec.counterparty_key, 'Unknown'),
                'narration', v_rec.narration,
                'balance_after', ROUND(v_rec.current_balance, 2),
                'confidence', 'MEDIUM',
                'suggested_start_date', v_rec.txn_date::text,
                'suggested_end_date', coalesce(v_stmt_end::text, v_rec.txn_date::text)
            );
        END IF;
    END IF;

    -- 3. If any recent credit was requested or fallback to the most recent credit
    SELECT 
        id,
        (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date AS txn_date,
        TO_CHAR(transaction_timestamp AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') AS txn_ts,
        amount,
        current_balance,
        clean_merchant_name,
        counterparty_key,
        narration,
        txn_kind
    INTO v_rec
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'CREDIT'
    ORDER BY transaction_timestamp DESC
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'found', true,
            'event_type', p_event_type,
            'match_reason', 'Most recent inbound credit',
            'event_date', v_rec.txn_date::text,
            'event_timestamp', v_rec.txn_ts,
            'amount', ROUND(v_rec.amount, 2),
            'sender_or_merchant', coalesce(v_rec.clean_merchant_name, v_rec.counterparty_key, 'Unknown'),
            'narration', v_rec.narration,
            'balance_after', ROUND(v_rec.current_balance, 2),
            'confidence', 'LOW',
            'suggested_start_date', v_rec.txn_date::text,
            'suggested_end_date', coalesce(v_stmt_end::text, v_rec.txn_date::text)
        );
    END IF;

    -- 4. Nothing found
    RETURN jsonb_build_object(
        'found', false,
        'event_type', p_event_type,
        'message', 'No credit or income events found for this user.'
    );
END;
$$;

-- 2. search_transactions
CREATE OR REPLACE FUNCTION public.search_transactions(
    p_query text,
    p_type text DEFAULT NULL,
    p_start_date date DEFAULT NULL,
    p_end_date date DEFAULT NULL,
    p_limit integer DEFAULT 10,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid uuid;
    v_eff_limit int := LEAST(COALESCE(p_limit, 10), 20);
    v_results jsonb;
    v_num_query numeric;
BEGIN
    v_uid := CASE 
        WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
        WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
        ELSE auth.uid()
    END;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('error', 'Unauthorized');
    END IF;

    -- Check if query is numeric
    BEGIN
        v_num_query := p_query::numeric;
    EXCEPTION WHEN OTHERS THEN
        v_num_query := NULL;
    END;

    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'id', id,
            'date', (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date::text,
            'timestamp', TO_CHAR(transaction_timestamp AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
            'type', UPPER(type),
            'amount', ROUND(amount, 2),
            'balance', ROUND(current_balance, 2),
            'merchant', coalesce(clean_merchant_name, counterparty_key, 'Unknown'),
            'narration', narration,
            'category', coalesce(habit_category, category, 'General'),
            'txn_kind', txn_kind
        )
    ), '[]'::jsonb)
    INTO v_results
    FROM (
        SELECT *
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND (p_type IS NULL OR UPPER(type) = UPPER(p_type))
          AND (p_start_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_start_date)
          AND (p_end_date IS NULL OR (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_end_date)
          AND (
              clean_merchant_name ILIKE '%' || p_query || '%'
              OR counterparty_key ILIKE '%' || p_query || '%'
              OR narration ILIKE '%' || p_query || '%'
              OR category ILIKE '%' || p_query || '%'
              OR habit_category ILIKE '%' || p_query || '%'
              OR (v_num_query IS NOT NULL AND amount = v_num_query)
          )
        ORDER BY transaction_timestamp DESC, id DESC
        LIMIT v_eff_limit
    ) t;

    RETURN jsonb_build_object(
        'query', p_query,
        'count', jsonb_array_length(v_results),
        'results', v_results
    );
END;
$$;
