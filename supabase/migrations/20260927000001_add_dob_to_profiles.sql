-- =============================================================================
-- Migration: 20260927000001_add_dob_to_profiles.sql
-- Description: Add date_of_birth column to public.profiles for DOB collection
-- Target Supabase Project: lqvzhffsqspwmahiajfm
-- =============================================================================

ALTER TABLE public.profiles 
  ADD COLUMN IF NOT EXISTS date_of_birth DATE;
