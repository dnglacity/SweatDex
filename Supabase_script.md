-- Migration: add format_slots column to game_rosters
-- Stores format-template slot assignments: keys are "$sectionIdx-$positionIdx",
-- values are player UUIDs.  Allows the format position assignments to persist
-- when a saved roster is closed and re-opened.

ALTER TABLE public.game_rosters
  ADD COLUMN IF NOT EXISTS format_slots jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Migration: add selected_roster_id column to matches
-- Persists the game roster the coach pinned to a match so it survives
-- navigating away and re-opening the match view.

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS selected_roster_id uuid
    REFERENCES public.game_rosters(id) ON DELETE SET NULL;
