-- =============================================================================
-- Migration: 20261006000000_add_income_profile_to_profiles.sql
-- Description: Adds income_type and expected_monthly_income columns to public.profiles
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

ALTER TABLE public.profiles 
  ADD COLUMN IF NOT EXISTS income_type TEXT,
  ADD COLUMN IF NOT EXISTS expected_monthly_income NUMERIC CHECK (expected_monthly_income >= 0);
