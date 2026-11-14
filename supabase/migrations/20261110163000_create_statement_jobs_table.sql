-- ==============================================================================
-- Migration: Create statement_jobs table & RLS policies
-- Dedicated schema for tracking asynchronous Financial Statement Intelligence jobs
-- from Modal.com OCR & Gemini extraction pipeline.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.statement_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    job_id TEXT NOT NULL,
    job_token TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'completed', 'failed', 'password_required')),
    filename TEXT,
    storage_path TEXT,
    document_type TEXT,                      -- 'bank_statement' | 'credit_card_statement'
    issuer_or_bank TEXT,
    page_count INTEGER,
    opening_balance NUMERIC,
    closing_balance NUMERIC,
    billing_cycle TEXT,
    payment_due_date TIMESTAMPTZ,
    total_transactions INTEGER DEFAULT 0,
    error_code TEXT,
    error_message TEXT,
    raw_result JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT unq_user_statement_job UNIQUE (user_id, job_id)
);

-- Enable Row Level Security
ALTER TABLE public.statement_jobs ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'statement_jobs' AND policyname = 'Users can view their own statement jobs'
    ) THEN
        CREATE POLICY "Users can view their own statement jobs"
            ON public.statement_jobs FOR SELECT
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'statement_jobs' AND policyname = 'Users can insert their own statement jobs'
    ) THEN
        CREATE POLICY "Users can insert their own statement jobs"
            ON public.statement_jobs FOR INSERT
            TO authenticated
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'statement_jobs' AND policyname = 'Users can update their own statement jobs'
    ) THEN
        CREATE POLICY "Users can update their own statement jobs"
            ON public.statement_jobs FOR UPDATE
            TO authenticated
            USING (auth.uid() = user_id)
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'statement_jobs' AND policyname = 'Users can delete their own statement jobs'
    ) THEN
        CREATE POLICY "Users can delete their own statement jobs"
            ON public.statement_jobs FOR DELETE
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;
END $$;

-- Indexes for lightning fast lookups
CREATE INDEX IF NOT EXISTS idx_statement_jobs_user_status 
    ON public.statement_jobs (user_id, status);

CREATE INDEX IF NOT EXISTS idx_statement_jobs_user_created 
    ON public.statement_jobs (user_id, created_at DESC);

-- Enable Supabase Realtime for statement_jobs
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' AND tablename = 'statement_jobs'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.statement_jobs;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- Safely ignore if publication does not exist or user lacks superuser
        NULL;
END $$;

