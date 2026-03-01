-- ============================================================
-- Apex On Deck — Supabase Consolidated Export Script
-- Run in the Supabase SQL Editor.
-- Copy the single JSON result into supabase_blueprint.json
-- (replaces supabase_blueprint.json, supabase_functions.json,
--  supabase_policies.json, and supabase_output.json).
-- ============================================================

SELECT jsonb_pretty(
  jsonb_build_object(

    -- --------------------------------------------------------
    -- 1. SCHEMA BLUEPRINT
    --    Columns from all public tables and views, ordered by
    --    table then ordinal position.
    -- --------------------------------------------------------
    'blueprint', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'table_name',     c.table_name,
          'column_name',    c.column_name,
          'data_type',      c.data_type,
          'is_nullable',    c.is_nullable,
          'column_default', c.column_default
        )
        ORDER BY c.table_name, c.ordinal_position
      )
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
    ),

    -- --------------------------------------------------------
    -- 2. FUNCTIONS
    --    Metadata + full definition for all routines in the
    --    public and private schemas (excludes aggregates).
    -- --------------------------------------------------------
    'functions', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'schema_name',   n.nspname,
          'function_name', p.proname,
          'arguments',     pg_get_function_arguments(p.oid),
          'return_type',   pg_get_function_result(p.oid),
          'security_type', CASE WHEN p.prosecdef THEN 'Security Definer' ELSE 'Security Invoker' END,
          'definition',    pg_get_functiondef(p.oid)
        )
        ORDER BY n.nspname, p.proname
      )
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname IN ('public', 'private')
        AND p.prokind IN ('f', 'p')
    ),

    -- --------------------------------------------------------
    -- 3. POLICIES
    --    All RLS policies on public tables.
    -- --------------------------------------------------------
    'policies', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'schemaname',        schemaname,
          'tablename',         tablename,
          'policyname',        policyname,
          'roles',             roles::text,
          'operation',         cmd,
          'using_expression',  qual,
          'check_expression',  with_check
        )
        ORDER BY tablename, policyname
      )
      FROM pg_policies
      WHERE schemaname = 'public'
    ),

    -- --------------------------------------------------------
    -- 4. TRIGGERS
    --    All triggers on public tables, including the full
    --    trigger function definition. Captures handle_new_user,
    --    fn_sync_player_membership_on_link, etc.
    -- --------------------------------------------------------
    'triggers', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'trigger_name',      t.trigger_name,
          'table_name',        t.event_object_table,
          'event',             t.event_manipulation,
          'timing',            t.action_timing,
          'orientation',       t.action_orientation,
          'condition',         t.action_condition,
          'function_schema',   n.nspname,
          'function_name',     p.proname,
          'function_definition', pg_get_functiondef(p.oid)
        )
        ORDER BY t.event_object_table, t.trigger_name
      )
      FROM information_schema.triggers t
      JOIN pg_trigger pt
        ON pt.tgname = t.trigger_name
      JOIN pg_class  pc
        ON pc.oid = pt.tgrelid
        AND pc.relname = t.event_object_table
      JOIN pg_proc   p
        ON p.oid = pt.tgfoid
      JOIN pg_namespace n
        ON n.oid = p.pronamespace
      WHERE t.trigger_schema = 'public'
        AND NOT pt.tgisinternal
    ),

    -- --------------------------------------------------------
    -- 5. FOREIGN KEYS
    --    Referential integrity constraints across public tables.
    --    Shows the constrained column(s) and what they reference.
    -- --------------------------------------------------------
    'foreign_keys', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'constraint_name',    tc.constraint_name,
          'table_name',         tc.table_name,
          'column_name',        kcu.column_name,
          'foreign_table_name', ccu.table_name,
          'foreign_column_name',ccu.column_name,
          'on_update',          rc.update_rule,
          'on_delete',          rc.delete_rule
        )
        ORDER BY tc.table_name, tc.constraint_name
      )
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu
        ON kcu.constraint_name = tc.constraint_name
        AND kcu.table_schema   = tc.table_schema
      JOIN information_schema.referential_constraints rc
        ON rc.constraint_name  = tc.constraint_name
        AND rc.constraint_schema = tc.table_schema
      JOIN information_schema.constraint_column_usage ccu
        ON ccu.constraint_name = rc.unique_constraint_name
        AND ccu.table_schema   = tc.table_schema
      WHERE tc.constraint_type = 'FOREIGN KEY'
        AND tc.table_schema    = 'public'
    ),

    -- --------------------------------------------------------
    -- 6. INDEXES
    --    All non-system indexes on public tables, including
    --    the full CREATE INDEX statement for reconstruction.
    -- --------------------------------------------------------
    'indexes', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'index_name',   i.relname,
          'table_name',   t.relname,
          'is_unique',    ix.indisunique,
          'is_primary',   ix.indisprimary,
          'definition',   pg_get_indexdef(ix.indexrelid)
        )
        ORDER BY t.relname, i.relname
      )
      FROM pg_index     ix
      JOIN pg_class     t  ON t.oid  = ix.indrelid
      JOIN pg_class     i  ON i.oid  = ix.indexrelid
      JOIN pg_namespace n  ON n.oid  = t.relnamespace
      WHERE n.nspname = 'public'
        AND t.relkind = 'r'          -- base tables only (not views)
        AND NOT ix.indisprimary      -- exclude PKs (already in blueprint)
    ),

    -- --------------------------------------------------------
    -- 7. VIEWS
    --    Definition (CREATE VIEW SQL) for every view in the
    --    public schema, e.g. v_owner_user_id, v_stuck_registrations.
    -- --------------------------------------------------------
    'views', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'view_name',   v.table_name,
          'definition',  pg_get_viewdef(
                           (quote_ident(v.table_schema) || '.' || quote_ident(v.table_name))::regclass,
                           true   -- pretty-print
                         )
        )
        ORDER BY v.table_name
      )
      FROM information_schema.views v
      WHERE v.table_schema = 'public'
    ),

    -- --------------------------------------------------------
    -- 8. RLS STATUS
    --    Which public tables have row-level security enabled
    --    and/or forced (forcerowsecurity applies to table owners).
    -- --------------------------------------------------------
    'rls_status', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'table_name',      c.relname,
          'rls_enabled',     c.relrowsecurity,
          'rls_forced',      c.relforcerowsecurity
        )
        ORDER BY c.relname
      )
      FROM pg_class     c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind  = 'r'
    )

  )
) AS consolidated_blueprint;
