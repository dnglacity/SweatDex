# Supabase Migration Script

## get_linked_match_roster RPC

Returns the opponent's enriched roster for a match. Fetches the linked match's
selected game roster, joins player names, and also returns the match format
template sections and enriched format slot assignments so the caller can render
the full section-based lineup.

```sql
CREATE OR REPLACE FUNCTION public.get_linked_match_roster(p_match_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_linked_id          UUID;
  v_roster_id          UUID;
  v_roster_title       TEXT;
  v_team_id            UUID;
  v_team_name          TEXT;
  v_raw_starters       JSONB;
  v_raw_subs           JSONB;
  v_starters           JSONB := '[]'::JSONB;
  v_subs               JSONB := '[]'::JSONB;
  v_template_id        UUID;
  v_raw_format_slots   JSONB;
  v_format_name        TEXT;
  v_format_sections    JSONB;
  v_enriched_slots     JSONB := '{}'::JSONB;
  v_slot_key           TEXT;
  v_slot_pid           UUID;
  v_slot_rec           RECORD;
BEGIN
  -- Verify caller is a member of the match's team.
  IF NOT EXISTS (
    SELECT 1 FROM matches m
    JOIN team_members tm ON tm.team_id = m.team_id
    WHERE m.id = p_match_id AND tm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;

  -- Get the linked match ID.
  SELECT linked_match_id INTO v_linked_id
  FROM matches WHERE id = p_match_id;

  IF v_linked_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Get the linked match's selected roster ID and team info.
  SELECT m.selected_roster_id, m.team_id, m.my_team_name
    INTO v_roster_id, v_team_id, v_team_name
  FROM matches m WHERE m.id = v_linked_id;

  IF v_roster_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Fetch the game roster data.
  SELECT gr.title, gr.starters, gr.substitutes,
         gr.match_format_template_id, gr.format_slots
    INTO v_roster_title, v_raw_starters, v_raw_subs,
         v_template_id, v_raw_format_slots
  FROM game_rosters gr WHERE gr.id = v_roster_id;

  IF v_roster_title IS NULL THEN
    RETURN NULL;
  END IF;

  -- Enrich starters with player names.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                slot->>'player_id',
      'name',              COALESCE(p.first_name || ' ' || p.last_name, ''),
      'position',          COALESCE(p.position, ''),
      'position_override', COALESCE(slot->>'position_override', '')
    ) ORDER BY (slot->>'slot_number')::INT
  ), '[]'::JSONB)
  INTO v_starters
  FROM jsonb_array_elements(v_raw_starters) AS slot
  LEFT JOIN players p ON p.id = (slot->>'player_id')::UUID
  WHERE slot->>'player_id' IS NOT NULL;

  -- Enrich substitutes with player names.
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',                slot->>'player_id',
      'name',              COALESCE(p.first_name || ' ' || p.last_name, ''),
      'position',          COALESCE(p.position, ''),
      'position_override', COALESCE(slot->>'position_override', '')
    ) ORDER BY (slot->>'slot_number')::INT
  ), '[]'::JSONB)
  INTO v_subs
  FROM jsonb_array_elements(v_raw_subs) AS slot
  LEFT JOIN players p ON p.id = (slot->>'player_id')::UUID
  WHERE slot->>'player_id' IS NOT NULL;

  -- Load format template if one is attached.
  IF v_template_id IS NOT NULL THEN
    SELECT mft.name, mft.sections
      INTO v_format_name, v_format_sections
    FROM match_format_templates mft WHERE mft.id = v_template_id;
  END IF;

  -- Enrich format_slots: convert {"0-0": "player-uuid", ...} into
  -- {"0-0": {"name": "...", "position": "...", "position_override": "..."}, ...}
  IF v_raw_format_slots IS NOT NULL AND v_raw_format_slots != '{}'::JSONB THEN
    FOR v_slot_rec IN SELECT key, value FROM jsonb_each_text(v_raw_format_slots)
    LOOP
      v_slot_key := v_slot_rec.key;
      v_slot_pid := v_slot_rec.value::UUID;
      v_enriched_slots := v_enriched_slots || jsonb_build_object(
        v_slot_key,
        (SELECT jsonb_build_object(
           'id',                p.id::TEXT,
           'name',              COALESCE(p.first_name || ' ' || p.last_name, ''),
           'position',          COALESCE(p.position, ''),
           'position_override', ''
         ) FROM players p WHERE p.id = v_slot_pid)
      );
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'team_name',       v_team_name,
    'roster_title',    v_roster_title,
    'starters',        v_starters,
    'substitutes',     v_subs,
    'format_name',     v_format_name,
    'format_sections', v_format_sections,
    'format_slots',    v_enriched_slots
  );
END;
$$;
```

## Core Match Format Templates

Global, sport-specific templates managed via Supabase Table Editor. No admin UI in the app.

```sql
-- Core match format templates (global, managed via Supabase Table Editor)
CREATE TABLE core_match_format_templates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  sport       TEXT,
  sections    JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE core_match_format_templates ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read; nobody can write from the app
CREATE POLICY "Authenticated users can read core templates"
  ON core_match_format_templates FOR SELECT
  TO authenticated
  USING (true);
```

**How to add templates via Supabase Table Editor:**
Insert rows into `core_match_format_templates`. `sections` is a JSONB array:
```json
[
  {"title": "Starters", "position_count": 5},
  {"title": "Bench",    "position_count": 7}
]
```
