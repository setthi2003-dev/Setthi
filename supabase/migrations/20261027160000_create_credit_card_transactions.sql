-- ==============================================================================
-- Migration: Create credit_card_transactions table & RLS policies
-- Dedicated schema for itemized Credit Card Statement transactions (e.g. Slice Bank)
-- completely segregated from bank_transactions and email_extracted_transactions.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.credit_card_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    statement_id TEXT,
    statement_pdf_path TEXT,
    card_last4 TEXT,
    card_issuer TEXT DEFAULT 'Slice Bank',
    billing_cycle TEXT,
    due_date TIMESTAMPTZ,
    transaction_date TIMESTAMPTZ NOT NULL,
    merchant_name TEXT NOT NULL,
    clean_merchant_name TEXT,
    category TEXT,
    payment_mode TEXT,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('DEBIT', 'CREDIT')),
    section TEXT NOT NULL CHECK (section IN ('SPEND', 'REFUND', 'CASHBACK', 'INTEREST', 'SURCHARGE')),
    amount NUMERIC(12, 2) NOT NULL,
    currency TEXT DEFAULT 'INR',
    reference_id TEXT NOT NULL,
    raw_details TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT unq_credit_card_txn UNIQUE (user_id, reference_id)
);

-- Enable RLS
ALTER TABLE public.credit_card_transactions ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'credit_card_transactions' AND policyname = 'Users can view their own credit card transactions'
    ) THEN
        CREATE POLICY "Users can view their own credit card transactions"
            ON public.credit_card_transactions FOR SELECT
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'credit_card_transactions' AND policyname = 'Users can insert their own credit card transactions'
    ) THEN
        CREATE POLICY "Users can insert their own credit card transactions"
            ON public.credit_card_transactions FOR INSERT
            TO authenticated
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'credit_card_transactions' AND policyname = 'Users can update their own credit card transactions'
    ) THEN
        CREATE POLICY "Users can update their own credit card transactions"
            ON public.credit_card_transactions FOR UPDATE
            TO authenticated
            USING (auth.uid() = user_id)
            WITH CHECK (auth.uid() = user_id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies 
        WHERE tablename = 'credit_card_transactions' AND policyname = 'Users can delete their own credit card transactions'
    ) THEN
        CREATE POLICY "Users can delete their own credit card transactions"
            ON public.credit_card_transactions FOR DELETE
            TO authenticated
            USING (auth.uid() = user_id);
    END IF;
END $$;

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_cct_user_date ON public.credit_card_transactions(user_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_cct_card_last4 ON public.credit_card_transactions(user_id, card_last4);
CREATE INDEX IF NOT EXISTS idx_cct_section ON public.credit_card_transactions(user_id, section);
