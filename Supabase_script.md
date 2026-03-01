-- Migration: ensure delete_account scrubs JSONB blobs in game_rosters
-- Run in Supabase SQL Editor

-- Step 1: Create/replace helper that removes a player from all game-roster JSONB arrays.
CREATE OR REPLACE FUNCTION public.scrub_deleted_player_from_rosters(p_player_id uuid)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $$
DECLARE
  v_roster       RECORD;
  v_new_starters jsonb;
  v_new_subs     jsonb;
BEGIN
  FOR v_roster IN
    SELECT id, starters, substitutes
    FROM   game_rosters
    WHERE  starters    @> jsonb_build_array(jsonb_build_object('player_id', p_player_id::text))
        OR substitutes @> jsonb_build_array(jsonb_build_object('player_id', p_player_id::text))
  LOOP
    SELECT COALESCE(jsonb_agg(elem ORDER BY ordinality), '[]'::jsonb)
    INTO   v_new_starters
    FROM   jsonb_array_elements(v_roster.starters) WITH ORDINALITY AS t(elem, ordinality)
    WHERE  (elem->>'player_id')::uuid <> p_player_id;

    SELECT COALESCE(jsonb_agg(elem ORDER BY ordinality), '[]'::jsonb)
    INTO   v_new_subs
    FROM   jsonb_array_elements(v_roster.substitutes) WITH ORDINALITY AS t(elem, ordinality)
    WHERE  (elem->>'player_id')::uuid <> p_player_id;

    UPDATE game_rosters
    SET    starters    = v_new_starters,
           substitutes = v_new_subs
    WHERE  id = v_roster.id;
  END LOOP;
END;
$$;

-- Step 2: Replace delete_account to scrub every player linked to the account
--         from game-roster JSONB blobs before tearing down the account rows.
CREATE OR REPLACE FUNCTION public.delete_account()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $$
DECLARE
  v_auth_uid  uuid := auth.uid();
  v_user_id   uuid;
  v_player_id uuid;
BEGIN
  -- Resolve public.users.id for this auth user.
  SELECT id INTO v_user_id
  FROM   public.users
  WHERE  user_id = v_auth_uid;

  -- Scrub every player linked to this account from historical game rosters
  -- (starters / substitutes JSONB arrays) before any rows are deleted.
  FOR v_player_id IN
    SELECT id FROM public.players WHERE user_id = v_user_id
  LOOP
    PERFORM public.scrub_deleted_player_from_rosters(v_player_id);
  END LOOP;

  -- Remove team memberships.
  DELETE FROM public.team_members WHERE user_id = v_user_id;

  -- Remove the public profile row.
  -- FK game_rosters.created_by → public.users.id (ON DELETE SET NULL) fires here,
  -- and FK players.user_id → public.users.id (ON DELETE SET NULL) fires here.
  DELETE FROM public.users WHERE id = v_user_id;

  -- Delete the auth user — this signs out all sessions.
  DELETE FROM auth.users WHERE id = v_auth_uid;
END;
$$;
