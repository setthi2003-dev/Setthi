-- Enable authenticated users to insert and update merchant categorization rules
-- This resolves PostgrestException 42501 (new row violates row-level security policy for table "merchant_categories")

DROP POLICY IF EXISTS "Allow authenticated insert on merchant_categories" ON public.merchant_categories;
CREATE POLICY "Allow authenticated insert on merchant_categories"
  ON public.merchant_categories
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated update on merchant_categories" ON public.merchant_categories;
CREATE POLICY "Allow authenticated update on merchant_categories"
  ON public.merchant_categories
  FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);
