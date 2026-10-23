-- Migration: compare_periods RPC (Phase 3)
-- Description: Deterministic comparative analysis between two calendar periods or months for Setthi AI Agent

CREATE OR REPLACE FUNCTION public.compare_periods(
    p_period1_start date,
    p_period1_end date,
    p_period2_start date,
    p_period2_end date,
    p_category text DEFAULT NULL,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uid uuid;
    v_p1_total numeric := 0.0;
    v_p1_spend numeric := 0.0;
    v_p1_p2p numeric := 0.0;
    v_p1_charges numeric := 0.0;
    v_p1_count integer := 0;

    v_p2_total numeric := 0.0;
    v_p2_spend numeric := 0.0;
    v_p2_p2p numeric := 0.0;
    v_p2_charges numeric := 0.0;
    v_p2_count integer := 0;

    v_diff numeric;
    v_pct_diff numeric;
    v_trend text;
BEGIN
    v_uid := CASE 
        WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
        WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
        ELSE auth.uid()
    END;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('error', 'Unauthorized');
    END IF;

    -- Period 1 metrics
    SELECT 
        coalesce(SUM(amount), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'SPEND' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'PERSON_OUT' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'BANK_FEE' THEN amount ELSE 0 END), 0.0),
        COUNT(*)
    INTO 
        v_p1_total,
        v_p1_spend,
        v_p1_p2p,
        v_p1_charges,
        v_p1_count
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'DEBIT'
      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_period1_start
      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_period1_end
      AND (p_category IS NULL OR coalesce(habit_category, category) ILIKE '%' || p_category || '%');

    -- Period 2 metrics
    SELECT 
        coalesce(SUM(amount), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'SPEND' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'PERSON_OUT' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN txn_kind = 'BANK_FEE' THEN amount ELSE 0 END), 0.0),
        COUNT(*)
    INTO 
        v_p2_total,
        v_p2_spend,
        v_p2_p2p,
        v_p2_charges,
        v_p2_count
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND UPPER(type) = 'DEBIT'
      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date >= p_period2_start
      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date <= p_period2_end
      AND (p_category IS NULL OR coalesce(habit_category, category) ILIKE '%' || p_category || '%');

    v_diff := ROUND(v_p2_spend - v_p1_spend, 2);

    IF v_p1_spend > 0 THEN
        v_pct_diff := ROUND(((v_p2_spend - v_p1_spend) / v_p1_spend) * 100.0, 1);
    ELSE
        v_pct_diff := NULL;
    END IF;

    IF v_diff > 0 THEN
        v_trend := 'higher';
    ELSIF v_diff < 0 THEN
        v_trend := 'lower';
    ELSE
        v_trend := 'equal';
    END IF;

    RETURN jsonb_build_object(
        'period_1', jsonb_build_object(
            'start_date', p_period1_start::text,
            'end_date', p_period1_end::text,
            'spend_at_shops', ROUND(v_p1_spend, 2),
            'total_money_out', ROUND(v_p1_total, 2),
            'sent_to_people', ROUND(v_p1_p2p, 2),
            'bank_charges', ROUND(v_p1_charges, 2),
            'transaction_count', v_p1_count
        ),
        'period_2', jsonb_build_object(
            'start_date', p_period2_start::text,
            'end_date', p_period2_end::text,
            'spend_at_shops', ROUND(v_p2_spend, 2),
            'total_money_out', ROUND(v_p2_total, 2),
            'sent_to_people', ROUND(v_p2_p2p, 2),
            'bank_charges', ROUND(v_p2_charges, 2),
            'transaction_count', v_p2_count
        ),
        'comparison', jsonb_build_object(
            'spend_difference', v_diff,
            'spend_percent_change', v_pct_diff,
            'trend', v_trend,
            'summary', CASE 
                WHEN v_pct_diff IS NOT NULL THEN 'Period 2 shop spend was ' || abs(v_pct_diff) || '% ' || v_trend || ' than Period 1.'
                ELSE 'Period 1 had zero shop spend recorded.'
            END
        )
    );
END;
$$;
