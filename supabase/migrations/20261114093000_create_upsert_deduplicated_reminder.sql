-- Migration: Add deduplicated reminder upsert function
-- Prevents duplicate alerts for the same underlying financial obligation across repeated email syncs,
-- multiple reminder notices (e.g. decline, retry, suspension), and multi-batch imports.

CREATE OR REPLACE FUNCTION public.upsert_deduplicated_reminder(p_reminder JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID;
    v_reminder_id TEXT;
    v_type TEXT;
    v_provider TEXT;
    v_due_date DATE;
    v_timing TEXT;
    v_amount NUMERIC;
    v_currency TEXT;
    v_amount_source TEXT;
    v_amount_evidence JSONB;
    v_review BOOLEAN;
    v_reminder_eligible BOOLEAN;
    v_new_msg_ids TEXT[];
    v_metadata JSONB;
    v_service_identity TEXT;
    v_billing_period TEXT;
    v_email_timestamp TIMESTAMPTZ;
    v_existing_id UUID;
    v_existing_reminder_id TEXT;
    v_existing_metadata JSONB;
    v_result JSONB;
BEGIN
    v_user_id := (p_reminder->>'user_id')::UUID;
    v_reminder_id := p_reminder->>'reminder_id';
    v_type := p_reminder->>'type';
    v_provider := p_reminder->>'provider';
    v_due_date := (p_reminder->>'due_date')::DATE;
    v_timing := COALESCE(p_reminder->>'timing', 'unknown');
    v_amount := (p_reminder->>'amount')::NUMERIC;
    v_currency := COALESCE(p_reminder->>'currency', 'INR');
    v_amount_source := p_reminder->>'amount_source';
    v_amount_evidence := p_reminder->'amount_evidence';
    v_review := COALESCE((p_reminder->>'review')::BOOLEAN, false);
    v_reminder_eligible := COALESCE((p_reminder->>'reminder_eligible')::BOOLEAN, true);
    v_metadata := COALESCE(p_reminder->'metadata', '{}'::JSONB);
    v_service_identity := lower(COALESCE(v_metadata->>'service_identity', v_provider));
    v_billing_period := v_metadata->>'billing_period';
    v_email_timestamp := COALESCE((v_metadata->>'email_timestamp')::TIMESTAMPTZ, now());
    
    -- Extract message IDs array
    SELECT COALESCE(array_agg(x::TEXT), ARRAY[]::TEXT[])
    INTO v_new_msg_ids
    FROM jsonb_array_elements_text(COALESCE(p_reminder->'source_message_ids', '[]'::JSONB)) AS x;

    -- Look for an existing active reminder representing the same obligation
    SELECT id, reminder_id, metadata
    INTO v_existing_id, v_existing_reminder_id, v_existing_metadata
    FROM public.reminders
    WHERE user_id = v_user_id
      AND is_dismissed = false
      AND (
          -- Exact reminder_id match
          reminder_id = v_reminder_id
          OR (
              -- Match by obligation characteristics:
              type = v_type
              -- 1. Service identity match: MUST match specific sub-service if known, or provider if unknown
              AND lower(COALESCE(metadata->>'service_identity', provider)) = v_service_identity
              -- 2. Currency match
              AND COALESCE(currency, 'INR') = v_currency
              -- 3. Amount match (exact match, or one is null and needs refinement)
              AND (
                  (v_amount IS NOT NULL AND amount IS NOT NULL AND amount = v_amount)
                  OR (v_amount IS NOT NULL AND amount IS NULL)
                  OR (v_amount IS NULL AND amount IS NOT NULL)
                  OR (v_amount IS NULL AND amount IS NULL)
              )
              -- 4. Billing period / cycle match:
              -- NEVER merge across different billing periods/cycles
              AND (
                  -- If explicit due_date is known on both, they must be the exact same date
                  (due_date IS NOT NULL AND v_due_date IS NOT NULL AND due_date = v_due_date)
                  -- If billing_period (YYYY-MM) is known on both, it must match
                  OR (
                      v_billing_period IS NOT NULL 
                      AND metadata->>'billing_period' IS NOT NULL 
                      AND metadata->>'billing_period' = v_billing_period
                  )
                  -- If undated / no explicit billing period, emails must be within 30 days of each other
                  OR (
                      due_date IS NULL AND v_due_date IS NULL
                      AND metadata->>'billing_period' IS NULL AND v_billing_period IS NULL
                      AND abs(extract(epoch from (
                          COALESCE((metadata->>'email_timestamp')::TIMESTAMPTZ, created_at) - v_email_timestamp
                      )) / 86400) <= 30
                  )
              )
          )
      )
    ORDER BY
        (reminder_id = v_reminder_id) DESC,
        created_at ASC
    LIMIT 1
    FOR UPDATE;

    IF v_existing_id IS NOT NULL THEN
        -- Merge into existing reminder
        UPDATE public.reminders
        SET
            source_message_ids = (
                SELECT array_agg(DISTINCT m)
                FROM unnest(COALESCE(public.reminders.source_message_ids, ARRAY[]::TEXT[]) || v_new_msg_ids) AS m
                WHERE m IS NOT NULL AND m <> ''
            ),
            -- Preserve confirmed values; do not overwrite with null or less specific
            amount = COALESCE(public.reminders.amount, v_amount),
            due_date = COALESCE(public.reminders.due_date, v_due_date),
            timing = CASE 
                WHEN public.reminders.timing IS NOT NULL AND public.reminders.timing <> 'unknown' THEN public.reminders.timing
                WHEN v_timing <> 'unknown' THEN v_timing 
                ELSE public.reminders.timing 
            END,
            amount_evidence = COALESCE(public.reminders.amount_evidence, v_amount_evidence),
            -- Merge metadata and source emails array
            metadata = jsonb_set(
                COALESCE(public.reminders.metadata, '{}'::JSONB) || v_metadata,
                '{source_emails}',
                (
                    SELECT jsonb_agg(DISTINCT elem)
                    FROM jsonb_array_elements(
                        COALESCE(public.reminders.metadata->'source_emails', '[]'::JSONB) || 
                        COALESCE(v_metadata->'source_emails', '[]'::JSONB)
                    ) AS elem
                )
            ),
            review = (public.reminders.review OR v_review),
            updated_at = now()
        WHERE id = v_existing_id
        RETURNING json_build_object(
            'id', id,
            'reminder_id', reminder_id,
            'action', 'updated',
            'provider', provider,
            'amount', amount,
            'source_message_count', cardinality(source_message_ids)
        )::JSONB INTO v_result;
    ELSE
        -- Insert new canonical obligation record
        INSERT INTO public.reminders (
            user_id,
            reminder_id,
            type,
            provider,
            due_date,
            timing,
            amount,
            currency,
            amount_source,
            amount_evidence,
            review,
            reminder_eligible,
            source_message_ids,
            metadata,
            updated_at
        ) VALUES (
            v_user_id,
            v_reminder_id,
            v_type,
            v_provider,
            v_due_date,
            v_timing,
            v_amount,
            v_currency,
            v_amount_source,
            v_amount_evidence,
            v_review,
            v_reminder_eligible,
            v_new_msg_ids,
            v_metadata,
            now()
        )
        ON CONFLICT (user_id, reminder_id) DO UPDATE SET
            source_message_ids = (
                SELECT array_agg(DISTINCT m)
                FROM unnest(COALESCE(public.reminders.source_message_ids, ARRAY[]::TEXT[]) || EXCLUDED.source_message_ids) AS m
                WHERE m IS NOT NULL AND m <> ''
            ),
            amount = COALESCE(public.reminders.amount, EXCLUDED.amount),
            due_date = COALESCE(public.reminders.due_date, EXCLUDED.due_date),
            metadata = public.reminders.metadata || EXCLUDED.metadata,
            updated_at = now()
        RETURNING json_build_object(
            'id', id,
            'reminder_id', reminder_id,
            'action', 'inserted',
            'provider', provider,
            'amount', amount,
            'source_message_count', cardinality(source_message_ids)
        )::JSONB INTO v_result;
    END IF;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_deduplicated_reminder(JSONB) TO authenticated, service_role;

