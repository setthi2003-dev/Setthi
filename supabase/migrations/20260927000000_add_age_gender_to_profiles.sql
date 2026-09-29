-- =============================================================================
-- Migration: 20260927000000_add_age_gender_to_profiles.sql
-- Description: Add age and gender columns to public.profiles for Apple Sign In & onboarding completion
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

ALTER TABLE public.profiles 
  ADD COLUMN IF NOT EXISTS age INT CHECK (age >= 0 AND age <= 130),
  ADD COLUMN IF NOT EXISTS gender TEXT;
