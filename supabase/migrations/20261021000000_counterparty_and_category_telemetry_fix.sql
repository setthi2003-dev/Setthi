-- Migration: 20261021000000_counterparty_and_category_telemetry_fix.sql
-- Fixes:
-- 1. extract_counterparty: correctly extracts party name from UPI/(DR|CR|REV)/ narrations (Canara Bank style) while preserving Kotak UPI format
-- 2. merchant_rules: adds patterns for SMS charges, mobile recharges, food & dining (Brik Oven, Cream Stone, Parijata, Glens), and shopping (Nestasia, Reliance)
-- 3. merchant_categories: upserts canonical merchant categorization rules
-- 4. tag_transactions: syncs categories and counterparties accurately
-- 5. get_telemetry_metrics: groups all debits across the period so no spend is dropped or hidden

-- 1. Update extract_counterparty
CREATE OR REPLACE FUNCTION public.extract_counterparty(p_narration text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select nullif(trim(regexp_replace(regexp_replace(upper(coalesce(
    case
      when p_narration ~* '^UPI/(DR|CR|REV)/'  then split_part(p_narration, '/', 4)
      when p_narration ~* '^UPI/'              then split_part(p_narration, '/', 2)
      when p_narration ~* '^(RECD:)?IMPS/'     then split_part(p_narration, '/', 3)
      when p_narration ~* '^(PCI|PCD)/'        then split_part(p_narration, '/', 3)
      when p_narration ~* '^MB:RECEIVED FROM'  then regexp_replace(regexp_replace(p_narration, '^MB:RECEIVED FROM\s+', '', 'i'), '\s+\S*\d\S*(\s+\d+)?\s*$', '')
      else null
    end, '')),
    '\s*UPI-\d+\s*', ' ', 'g'), '\s+', ' ', 'g')), '')
$function$;

-- 2. Update merchant_rules
UPDATE public.merchant_rules
SET pattern = '^(REM )?CHRG|DECLINE FEE|SMS ALERT|SMS CHARG|EXCESS SMS'
WHERE id = 1;

UPDATE public.merchant_rules
SET pattern = '\m(AIRTEL|JIO|VODAFONE|BSNL|ELECTRICITY|BESCOM|DTH|RECHARGE|PHONEPE|PAYTM|CRED|BILLDESK)\M'
WHERE id = 9;

UPDATE public.merchant_rules
SET pattern = '\m(AMAZON|FLIPKART|MYNTRA|MEESHO|AJIO|DECATHLON|NESTASI\w*|RELIANCE)\M'
WHERE id = 10;

UPDATE public.merchant_rules
SET pattern = '\m(SWIGGY|ZOMATO|DOMINOS|KFC|MCDONALDS?|CAFE|COFFEE|TEA|CHAI|DHABA|HOTEL|RESTAURANT|VADA|TIFFEN|TIFFIN|BIRYANI|PIZZA|BAKERY|ICE ?CR\w*|JUICE|SWEETS|CHEF|FOODS?|SNACKS?|NATURALS|MUNCHBOX|CHOCOLATE|IBACO|LICKEES|IYENGAR|AYANGAR|INDIAN S|BRIK OVEN|GLENS?|CREAM STO\w*|PARIJAT\w*|BAKEHOUSE)\M'
WHERE id = 11;

-- 3. Upsert merchant_categories
INSERT INTO public.merchant_categories (keyword, clean_name, category)
VALUES
    ('meesho', 'Meesho', 'Shopping'),
    ('nestasia', 'Nestasia', 'Shopping'),
    ('nestasi', 'Nestasia', 'Shopping'),
    ('reliance', 'Reliance Retail', 'Shopping'),
    ('brik oven', 'Brik Oven', 'Food & Dining'),
    ('glens bakehouse', 'Glen''s Bakehouse', 'Food & Dining'),
    ('glens bak', 'Glen''s Bakehouse', 'Food & Dining'),
    ('cream stone', 'Cream Stone', 'Food & Dining'),
    ('cream sto', 'Cream Stone', 'Food & Dining'),
    ('parijata', 'Parijata', 'Food & Dining'),
    ('parijat ha', 'Parijata', 'Food & Dining'),
    ('phonepe', 'PhonePe', 'Bills & Utilities'),
    ('sms charges', 'SMS Charges', 'Bank Charges'),
    ('sms alert', 'SMS Alert', 'Bank Charges')
ON CONFLICT (keyword) DO UPDATE
SET clean_name = EXCLUDED.clean_name,
    category = EXCLUDED.category;

-- 4. Update tag_transactions
CREATE OR REPLACE FUNCTION public.tag_transactions(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r_rule record;
  v_out jsonb;
begin
  -- statement order, taken from the row number inside txn_id
  update bank_transactions set seq = split_part(txn_id, '_', 3)::int
   where user_id = p_user_id and seq is null and txn_id ~ '^STMT_[0-9-]+_[0-9]+_';

  -- who was paid / who paid, and a full reset of old tags (so fixed rules really take effect)
  update bank_transactions
     set counterparty_key = public.extract_counterparty(narration),
         txn_kind       = case when tag_source = 'user' then txn_kind end,
         habit_category = case when tag_source = 'user' then habit_category end,
         tag_source     = case when tag_source = 'user' then tag_source end
   where user_id = p_user_id;

  -- keyword rules, in priority order, whole words only
  for r_rule in select * from merchant_rules order by priority loop
    update bank_transactions b
       set txn_kind = case when r_rule.kind in ('BANK_FEE','BANK_INTEREST') then r_rule.kind
                           when b.type = 'CREDIT' then 'REFUND'
                           else 'SPEND' end,
           habit_category = r_rule.category,
           tag_source = 'rule'
     where b.user_id = p_user_id and b.txn_kind is null
       and upper(b.narration) ~ r_rule.pattern;
  end loop;

  -- people: a name that both sends you money and receives money is a person, not a shop
  update bank_transactions b
     set txn_kind = case when b.type = 'CREDIT' then 'PERSON_IN' else 'PERSON_OUT' end,
         habit_category = 'People',
         tag_source = 'two_way'
   where b.user_id = p_user_id and b.txn_kind is null and b.counterparty_key is not null
     and exists (
       select 1 from bank_transactions o
        where o.user_id = p_user_id and o.type <> b.type and o.counterparty_key is not null
          and (   o.counterparty_key = b.counterparty_key
               or (length(o.counterparty_key) >= 6 and b.counterparty_key like o.counterparty_key || '%')
               or (length(b.counterparty_key) >= 6 and o.counterparty_key like b.counterparty_key || '%')));

  -- every other credit is money received from a person
  update bank_transactions
     set txn_kind = 'PERSON_IN', habit_category = 'People', tag_source = 'default_credit'
   where user_id = p_user_id and txn_kind is null and type = 'CREDIT';

  -- every other debit: small = local shop or stall, 500+ = we cannot tell shop from person
  update bank_transactions
     set txn_kind       = case when amount >= 500 then 'UNSURE' else 'SPEND' end,
         habit_category = case when amount >= 500 then 'Unclear (shop or person)' else 'Local shops & stalls' end,
         tag_source     = case when amount >= 500 then 'needs_confirmation' else 'small_ticket' end
   where user_id = p_user_id and txn_kind is null and type = 'DEBIT';

  -- sync category and clean_merchant_name where category was null
  update bank_transactions
     set category = coalesce(category, habit_category),
         clean_merchant_name = coalesce(clean_merchant_name, initcap(counterparty_key))
   where user_id = p_user_id and (category is null or clean_merchant_name is null);

  select jsonb_object_agg(txn_kind, jsonb_build_object('rows', n, 'total', tot)) into v_out
  from (select txn_kind, count(*) n, round(sum(amount), 2) tot
          from bank_transactions where user_id = p_user_id group by txn_kind) z;
  return v_out;
end;
$function$;

-- 5. Update get_telemetry_metrics
CREATE OR REPLACE FUNCTION public.get_telemetry_metrics(
    p_user_id uuid DEFAULT auth.uid(),
    p_period text DEFAULT 'all'::text,
    p_today date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
    v_uid uuid;
    v_eff_today date;
    v_as_of date;
    v_statement_start date;
    v_period_start date;
    v_period_end date;
    v_days_in_period integer;
    v_is_partial boolean := false;
    v_anchor_month_start date;
    
    v_total_inflow numeric := 0.0;
    v_total_outflow numeric := 0.0;
    v_spend_at_shops numeric := 0.0;
    v_sent_to_people numeric := 0.0;
    v_unclear_payments numeric := 0.0;
    v_unclear_count integer := 0;
    v_bank_charges numeric := 0.0;
    v_received_from_people numeric := 0.0;
    v_refunds numeric := 0.0;
    v_interest numeric := 0.0;
    v_net_change numeric := 0.0;
    
    v_daily_velocity numeric := 0.0;
    v_daily_outflow numeric := 0.0;
    
    v_channels_json jsonb := '[]'::jsonb;
    v_categories_json jsonb := '[]'::jsonb;
    v_weekly_outflow_json jsonb := '[]'::jsonb;
BEGIN
    v_uid := CASE 
        WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
        WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
        ELSE auth.uid()
    END;

    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('error', 'Unauthorized');
    END IF;

    v_eff_today := coalesce(p_today, (now() AT TIME ZONE 'Asia/Kolkata')::date);

    SELECT 
        MIN((transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date),
        MAX((transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date)
    INTO v_statement_start, v_as_of
    FROM public.bank_transactions
    WHERE user_id = v_uid;

    IF v_as_of IS NULL THEN
        RETURN jsonb_build_object('available', false, 'reason', 'No transactions found');
    END IF;

    v_anchor_month_start := date_trunc('month', v_as_of)::date;

    IF p_period = 'month' THEN
        v_period_start := GREATEST(v_anchor_month_start, v_statement_start);
        v_period_end := v_as_of;
        v_days_in_period := v_period_end - v_period_start + 1;
        v_is_partial := (v_as_of < (v_anchor_month_start + interval '1 month - 1 day')::date) OR (v_statement_start > v_anchor_month_start);
    ELSIF p_period = '7d' THEN
        v_period_start := GREATEST(v_statement_start, v_as_of - 6);
        v_period_end := v_as_of;
        v_days_in_period := v_period_end - v_period_start + 1;
        v_is_partial := false;
    ELSE -- 'all'
        v_period_start := v_statement_start;
        v_period_end := v_as_of;
        v_days_in_period := v_as_of - v_statement_start + 1;
        v_is_partial := false;
    END IF;

    SELECT 
        coalesce(SUM(CASE WHEN type = 'CREDIT' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'DEBIT' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'DEBIT' AND (txn_kind = 'SPEND' OR (txn_kind IS NULL AND coalesce(habit_category, category) NOT IN ('People', 'Transfers', 'Bank charges', 'Bank Charges'))) THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'DEBIT' AND (txn_kind = 'PERSON_OUT' OR coalesce(habit_category, category) IN ('People', 'Transfers')) THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'DEBIT' AND txn_kind = 'UNSURE' THEN amount ELSE 0 END), 0.0),
        coalesce(COUNT(*) FILTER (WHERE type = 'DEBIT' AND txn_kind = 'UNSURE'), 0),
        coalesce(SUM(CASE WHEN type = 'DEBIT' AND (txn_kind = 'BANK_FEE' OR coalesce(habit_category, category) IN ('Bank charges', 'Bank Charges')) THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'CREDIT' AND txn_kind = 'PERSON_IN' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'CREDIT' AND txn_kind = 'REFUND' THEN amount ELSE 0 END), 0.0),
        coalesce(SUM(CASE WHEN type = 'CREDIT' AND (txn_kind = 'BANK_INTEREST' OR coalesce(habit_category, category) = 'Interest') THEN amount ELSE 0 END), 0.0)
    INTO 
        v_total_inflow,
        v_total_outflow,
        v_spend_at_shops,
        v_sent_to_people,
        v_unclear_payments,
        v_unclear_count,
        v_bank_charges,
        v_received_from_people,
        v_refunds,
        v_interest
    FROM public.bank_transactions
    WHERE user_id = v_uid
      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_period_start AND v_period_end;

    v_net_change := v_total_inflow - v_total_outflow;
    v_daily_velocity := ROUND(v_spend_at_shops / NULLIF(v_days_in_period, 0)::numeric, 2);
    v_daily_outflow := ROUND(v_total_outflow / NULLIF(v_days_in_period, 0)::numeric, 2);

    WITH debit_channels AS (
        SELECT 
            CASE
                WHEN narration ~* '^(PCI|PCD)/' THEN 'CARD'
                WHEN narration ~* '^UPI/' THEN 'UPI'
                WHEN narration ~* '^((RECD:)?IMPS/|MB:RECEIVED)' THEN 'IMPS'
                WHEN txn_kind IN ('BANK_FEE', 'BANK_INTEREST') THEN 'BANK'
                ELSE 'OTHER'
            END AS ch_mode,
            amount
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND type = 'DEBIT'
          AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_period_start AND v_period_end
    ),
    ch_summary AS (
        SELECT 
            ch_mode AS mode,
            SUM(amount) AS ch_amount,
            COUNT(*) AS ch_count,
            ROUND((SUM(amount) / NULLIF(v_total_outflow, 0)) * 100.0, 1) AS ch_pct
        FROM debit_channels
        GROUP BY ch_mode
        ORDER BY ch_amount DESC
    )
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'mode', mode,
                'amount', ch_amount,
                'count', ch_count,
                'percentage', ch_pct
            )
        ),
        '[]'::jsonb
    )
    INTO v_channels_json
    FROM ch_summary;

    -- Category distribution reflects ALL debits in the period grouped by category
    WITH spend_cats AS (
        SELECT 
            coalesce(habit_category, category, 'Uncategorized') AS cat_name,
            SUM(amount) AS cat_amount,
            COUNT(*) AS cat_count,
            ROUND((SUM(amount) / NULLIF(v_total_outflow, 0)) * 100.0, 1) AS cat_pct
        FROM public.bank_transactions
        WHERE user_id = v_uid
          AND type = 'DEBIT'
          AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_period_start AND v_period_end
        GROUP BY coalesce(habit_category, category, 'Uncategorized')
        ORDER BY cat_amount DESC
    )
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'category', cat_name,
                'amount', cat_amount,
                'count', cat_count,
                'percentage', cat_pct
            )
        ),
        '[]'::jsonb
    )
    INTO v_categories_json
    FROM spend_cats;

    WITH weeks_def AS (
        SELECT 
            1 AS w_num, 
            v_anchor_month_start AS w_start, 
            v_anchor_month_start + 6 AS w_end
        UNION ALL
        SELECT 
            2, 
            v_anchor_month_start + 7, 
            v_anchor_month_start + 13
        UNION ALL
        SELECT 
            3, 
            v_anchor_month_start + 14, 
            v_anchor_month_start + 20
        UNION ALL
        SELECT 
            4, 
            v_anchor_month_start + 21, 
            (v_anchor_month_start + interval '1 month - 1 day')::date
    ),
    weeks_calc AS (
        SELECT 
            w.w_num,
            w.w_start,
            w.w_end,
            CASE 
                WHEN w.w_start > v_as_of THEN null
                WHEN w.w_end < v_statement_start THEN null
                ELSE (
                    SELECT coalesce(SUM(amount), 0.0)
                    FROM public.bank_transactions
                    WHERE user_id = v_uid
                      AND type = 'DEBIT'
                      AND (transaction_timestamp AT TIME ZONE 'Asia/Kolkata')::date BETWEEN GREATEST(v_statement_start, w.w_start) AND LEAST(v_as_of, w.w_end)
                )
            END AS w_amount,
            (w.w_start <= v_as_of AND w.w_end > v_as_of) AS is_w_partial
        FROM weeks_def w
    )
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'week', w_num,
                'start_date', w_start,
                'end_date', w_end,
                'amount', w_amount,
                'partial', is_w_partial
            )
            ORDER BY w_num
        ),
        '[]'::jsonb
    )
    INTO v_weekly_outflow_json
    FROM weeks_calc;

    RETURN jsonb_build_object(
        'data_as_of', v_as_of,
        'statement_start', v_statement_start,
        'period', p_period,
        'period_start', v_period_start,
        'period_end', v_period_end,
        'days_in_period', v_days_in_period,
        'is_partial', v_is_partial,
        'days_since_statement_end', (v_eff_today - v_as_of),
        'total_inflow', v_total_inflow,
        'total_outflow', v_total_outflow,
        'total_spent', v_total_outflow,
        'net_change', v_net_change,
        'spend_at_shops', v_spend_at_shops,
        'sent_to_people', v_sent_to_people,
        'unclear_payments', v_unclear_payments,
        'unclear_count', v_unclear_count,
        'bank_charges', v_bank_charges,
        'received_from_people', v_received_from_people,
        'refunds', v_refunds,
        'interest', v_interest,
        'daily_velocity', v_daily_velocity,
        'daily_outflow', v_daily_outflow,
        'channel_distribution', v_channels_json,
        'category_distribution', v_categories_json,
        'weekly_outflow_velocity', v_weekly_outflow_json,
        'financial_health_score', null,
        'savings_ratio', null,
        'discretionary_ratio', null,
        'impulse_spent', null,
        'notes', ARRAY[
            'Anchor date is the statement end date (' || v_as_of::text || ')',
            'Channel distribution reflects DEBITS ONLY',
            'Category distribution reflects all debits grouped by category',
            'total_spent includes payments to people and bank charges for backward compatibility'
        ]
    );
END;
$function$;
