-- Migration: User Memory Engine (Phase 2)
-- Description: Persistent memory table and helper RPCs for Setthi AI Agent

CREATE TABLE IF NOT EXISTS public.user_memory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  memory_type TEXT NOT NULL, -- 'fact', 'preference', 'goal', 'event_anchor'
  content TEXT NOT NULL,
  confidence REAL DEFAULT 1.0,
  source TEXT DEFAULT 'inferred', -- 'user_stated', 'inferred', 'system'
  valid_from TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  is_active BOOLEAN DEFAULT true
);

CREATE INDEX IF NOT EXISTS idx_user_memory_user_type
  ON public.user_memory(user_id, memory_type, is_active);

ALTER TABLE public.user_memory ENABLE ROW LEVEL SECURITY;

DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'user_memory' AND policyname = 'Users can manage their own memories'
  ) THEN
    CREATE POLICY "Users can manage their own memories"
      ON public.user_memory
      FOR ALL
      TO authenticated
      USING (auth.uid() = user_id)
      WITH CHECK (auth.uid() = user_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE tablename = 'user_memory' AND policyname = 'Service role full access on user_memory'
  ) THEN
    CREATE POLICY "Service role full access on user_memory"
      ON public.user_memory
      FOR ALL
      TO service_role
      USING (true)
      WITH CHECK (true);
  END IF;
END $$;

-- RPC: save_user_memory
CREATE OR REPLACE FUNCTION public.save_user_memory(
  p_memory_type TEXT,
  p_content TEXT,
  p_confidence REAL DEFAULT 1.0,
  p_source TEXT DEFAULT 'inferred',
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID;
  v_existing_id UUID;
  v_res RECORD;
BEGIN
  v_uid := CASE 
      WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
      WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
      ELSE auth.uid()
  END;

  IF v_uid IS NULL THEN
      RETURN jsonb_build_object('error', 'Unauthorized');
  END IF;

  -- Check if very similar active memory already exists for this user and type
  SELECT id INTO v_existing_id
  FROM public.user_memory
  WHERE user_id = v_uid
    AND memory_type = p_memory_type
    AND is_active = true
    AND (LOWER(content) = LOWER(trim(p_content)) OR content ILIKE '%' || trim(p_content) || '%')
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.user_memory
    SET confidence = GREATEST(confidence, p_confidence),
        updated_at = now(),
        source = COALESCE(p_source, source)
    WHERE id = v_existing_id
    RETURNING id, memory_type, content, confidence INTO v_res;

    RETURN jsonb_build_object(
      'saved', true,
      'status', 'updated',
      'id', v_res.id,
      'memory_type', v_res.memory_type,
      'content', v_res.content,
      'confidence', v_res.confidence
    );
  ELSE
    INSERT INTO public.user_memory (user_id, memory_type, content, confidence, source)
    VALUES (v_uid, p_memory_type, trim(p_content), p_confidence, p_source)
    RETURNING id, memory_type, content, confidence INTO v_res;

    RETURN jsonb_build_object(
      'saved', true,
      'status', 'created',
      'id', v_res.id,
      'memory_type', v_res.memory_type,
      'content', v_res.content,
      'confidence', v_res.confidence
    );
  END IF;
END;
$$;

-- RPC: recall_user_memories
CREATE OR REPLACE FUNCTION public.recall_user_memories(
  p_query TEXT DEFAULT NULL,
  p_memory_type TEXT DEFAULT NULL,
  p_limit INT DEFAULT 10,
  p_user_id UUID DEFAULT auth.uid()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID;
  v_results JSONB;
BEGIN
  v_uid := CASE 
      WHEN auth.role() = 'service_role' THEN coalesce(p_user_id, auth.uid())
      WHEN auth.role() IS NULL AND session_user IN ('postgres', 'supabase_admin') THEN coalesce(p_user_id, auth.uid())
      ELSE auth.uid()
  END;

  IF v_uid IS NULL THEN
      RETURN jsonb_build_object('error', 'Unauthorized');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', id,
      'type', memory_type,
      'content', content,
      'confidence', confidence,
      'source', source,
      'updated_at', updated_at
    )
  ), '[]'::jsonb)
  INTO v_results
  FROM (
    SELECT id, memory_type, content, confidence, source, updated_at
    FROM public.user_memory
    WHERE user_id = v_uid
      AND is_active = true
      AND (p_memory_type IS NULL OR memory_type = p_memory_type)
      AND (p_query IS NULL OR content ILIKE '%' || p_query || '%')
    ORDER BY updated_at DESC
    LIMIT LEAST(COALESCE(p_limit, 10), 20)
  ) sub;

  RETURN jsonb_build_object(
    'count', jsonb_array_length(v_results),
    'memories', v_results
  );
END;
$$;
