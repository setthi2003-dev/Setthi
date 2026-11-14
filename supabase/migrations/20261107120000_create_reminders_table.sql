-- ==============================================================================
-- Migration: Create reminders table & RLS policies
-- Dedicated schema for Setthi Serverless ML Reminders (Trial Endings,
-- Subscription Renewals, and Credit Card Statements) output by Modal.com pipeline.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.reminders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    reminder_id TEXT NOT NULL,                     -- Deterministic 'sth_...' key from Modal ML
    type TEXT NOT NULL CHECK (type IN ('trial_ending', 'subscription', 'credit_card_statement')),
    provider TEXT NOT NULL,                        -- e.g. 'Netflix', 'HDFC Bank', 'Google One'
    due_date DATE,                                 -- Event due or trial expiration date (nullable for undated notices)
    timing TEXT NOT NULL CHECK (timing IN ('upcoming', 'today', 'past', 'unknown')),
    amount NUMERIC(12, 2),                         -- Primary amount extracted by GLiNER 2.5
    currency TEXT DEFAULT 'INR',
    amount_source TEXT DEFAULT 'gliner2.5',
    amount_evidence JSONB,                         -- { text, confidence, model_label, source_span }
    review BOOLEAN DEFAULT FALSE,                  -- Flagged if forwarded, unverified, or low confidence
    reminder_eligible BOOLEAN DEFAULT TRUE,        -- Qualified for push notifications
    source_message_ids TEXT[] DEFAULT '{}',        -- Gmail message IDs representing this event
    is_dismissed BOOLEAN DEFAULT FALSE,            -- User interaction state
    is_actioned BOOLEAN DEFAULT FALSE,             -- User marked as paid/cancelled
    delivered_keys TEXT[] DEFAULT '{}',            -- Notification tracking: e.g. ['7d', '1d', 'day_of']
    metadata JSONB DEFAULT '{}',                   -- Extra diagnostic info
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT unq_user_reminder UNIQUE (user_id, reminder_id)
);

-- Enable Row Level Security
ALTER TABLE public.reminders ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'reminders' AND policyname = 'Users can view their own reminders'
    ) THEN
        CREATE POLICY "Users can view their own reminders"
            ON public.reminders FOR SELECT
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'reminders' AND policyname = 'Users can insert their own reminders'
    ) THEN
        CREATE POLICY "Users can insert their own reminders"
            ON public.reminders FOR INSERT
            TO authenticated
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'reminders' AND policyname = 'Users can update their own reminders'
    ) THEN
        CREATE POLICY "Users can update their own reminders"
            ON public.reminders FOR UPDATE
            TO authenticated
            USING (auth.uid() = user_id)
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'reminders' AND policyname = 'Users can delete their own reminders'
    ) THEN
        CREATE POLICY "Users can delete their own reminders"
            ON public.reminders FOR DELETE
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'reminders' AND policyname = 'Service role full access to reminders'
    ) THEN
        CREATE POLICY "Service role full access to reminders"
            ON public.reminders FOR ALL
            TO service_role
            USING (true)
            WITH CHECK (true);
    END IF;
END $$;

-- Grant access to authenticated and service_role
GRANT ALL ON TABLE public.reminders TO authenticated, service_role;

-- Performance Indexes
CREATE INDEX IF NOT EXISTS idx_reminders_user_due_date ON public.reminders(user_id, due_date ASC);
CREATE INDEX IF NOT EXISTS idx_reminders_user_type ON public.reminders(user_id, type);
CREATE INDEX IF NOT EXISTS idx_reminders_user_eligible ON public.reminders(user_id, reminder_eligible, timing);
CREATE INDEX IF NOT EXISTS idx_reminders_user_dismissed ON public.reminders(user_id, is_dismissed);

-- ==============================================================================
-- Optional Trigger: Sync Verified Subscription Reminders to user_recurring_commitments
-- Automatically keeps Cashflow Rhythm and Habit engines synchronized.
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.sync_reminder_subscription_to_commitment()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.type = 'subscription' 
       AND NEW.amount IS NOT NULL 
       AND NEW.amount > 0 
       AND NEW.provider IS NOT NULL 
       AND trim(NEW.provider) <> '' THEN
        INSERT INTO public.user_recurring_commitments (
            user_id,
            merchant_name,
            category,
            expected_amount,
            frequency,
            typical_due_day,
            is_confirmed,
            is_active,
            updated_at
        ) VALUES (
            NEW.user_id,
            trim(NEW.provider),
            'Subscription',
            NEW.amount,
            'MONTHLY',
            COALESCE(EXTRACT(DAY FROM NEW.due_date)::INT, 1),
            TRUE,
            TRUE,
            now()
        )
        ON CONFLICT (user_id, merchant_name) DO UPDATE SET
            expected_amount = EXCLUDED.expected_amount,
            typical_due_day = COALESCE(EXCLUDED.typical_due_day, public.user_recurring_commitments.typical_due_day),
            updated_at = now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_sync_reminder_subscription ON public.reminders;
CREATE TRIGGER trg_sync_reminder_subscription
    AFTER INSERT OR UPDATE ON public.reminders
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_reminder_subscription_to_commitment();

