## v1.12 — Scrub deleted player data from historical game rosters

Run the following SQL in the Supabase SQL Editor.

---

### 1. Helper: `scrub_deleted_player_from_rosters`

Walks every `game_rosters` row and removes entries whose `player_id` matches
the deleted player from both the `starters` and `substitutes` JSONB arrays.
Called internally by `delete_player` and `delete_account`.

```sql
CREATE OR REPLACE FUNCTION public.scrub_deleted_player_from_rosters(
  p_player_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_roster RECORD;
  v_new_starters  jsonb;
  v_new_subs      jsonb;
BEGIN
  FOR v_roster IN
    SELECT id, starters, substitutes
    FROM   game_rosters
    WHERE  starters    @> jsonb_build_array(jsonb_build_object('player_id', p_player_id::text))
        OR substitutes @> jsonb_build_array(jsonb_build_object('player_id', p_player_id::text))
  LOOP
    -- Filter out any element whose player_id matches the deleted player.
    SELECT COALESCE(
             jsonb_agg(elem ORDER BY ordinality),
             '[]'::jsonb
           )
    INTO   v_new_starters
    FROM   jsonb_array_elements(v_roster.starters) WITH ORDINALITY AS t(elem, ordinality)
    WHERE  (elem->>'player_id')::uuid <> p_player_id;

    SELECT COALESCE(
             jsonb_agg(elem ORDER BY ordinality),
             '[]'::jsonb
           )
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
```

---

### 2. RPC: `delete_player`

SECURITY DEFINER RPC callable by coaches/owners. Scrubs the player from all
historical game rosters before deleting the `players` row. RLS on `players`
still enforces that the caller has write access to the team.

```sql
CREATE OR REPLACE FUNCTION public.delete_player(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_team_id uuid;
  v_role    text;
BEGIN
  -- Resolve the player's team so we can authorise the caller.
  SELECT team_id INTO v_team_id
  FROM   players
  WHERE  id = p_player_id;

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'Player not found.';
  END IF;

  -- Only owners, coaches, and team_managers may delete players.
  SELECT role INTO v_role
  FROM   team_members
  WHERE  team_id = v_team_id
    AND  user_id = private.get_my_user_id();

  IF v_role IS NULL OR v_role NOT IN ('owner', 'coach', 'team_manager') THEN
    RAISE EXCEPTION 'Only coaches and owners can delete players.';
  END IF;

  -- 1. Scrub the player from all historical game rosters.
  PERFORM public.scrub_deleted_player_from_rosters(p_player_id);

  -- 2. Delete the player row (cascades handle guardian_links etc.).
  DELETE FROM players WHERE id = p_player_id;
END;
$$;
```

---

### 3. RPC: `delete_account`

Deletes the calling user's own account. Before removing auth/public rows, it
scrubs every player linked to the account from all historical game rosters.
Replace the existing `delete_account` function if one already exists.

```sql
CREATE OR REPLACE FUNCTION public.delete_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  -- Scrub every player linked to this account from historical game rosters.
  FOR v_player_id IN
    SELECT id FROM players WHERE user_id = v_user_id
  LOOP
    PERFORM public.scrub_deleted_player_from_rosters(v_player_id);
  END LOOP;

  -- Remove team memberships (cascades or explicit).
  DELETE FROM team_members WHERE user_id = v_user_id;

  -- Remove the public profile row.
  DELETE FROM public.users WHERE id = v_user_id;

  -- Delete the auth user — this signs out all sessions.
  DELETE FROM auth.users WHERE id = v_auth_uid;
END;
$$;
```

---

### 4. Grants

Ensure authenticated users can call the new RPCs.

```sql
GRANT EXECUTE ON FUNCTION public.delete_player(uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_account()           TO authenticated;
-- scrub_deleted_player_from_rosters is internal; no direct grant needed.
REVOKE EXECUTE ON FUNCTION public.scrub_deleted_player_from_rosters(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.scrub_deleted_player_from_rosters(uuid) TO authenticated;
```
