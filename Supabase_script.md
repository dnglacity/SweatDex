# AOD — Migration: players.name → first_name + last_name

**Run in:** Supabase Dashboard → SQL Editor (requires service-role access)

Run sections in order. Each is safe to re-run (`IF NOT EXISTS`, `IF EXISTS`).

---

## Section 1 — Add first_name and last_name columns

```sql
ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS first_name TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS last_name  TEXT NOT NULL DEFAULT '';
```

---

## Section 2 — Migrate data from name → first_name / last_name

Splits on the first space. Players with a single-word name get it as first_name.

```sql
UPDATE public.players
SET
  first_name = TRIM(SPLIT_PART(name, ' ', 1)),
  last_name  = TRIM(SUBSTRING(name FROM POSITION(' ' IN name) + 1))
WHERE first_name = '' AND last_name = '';
```

---

## Section 3 — Keep name in sync via a generated column (optional)

If you want the DB to maintain `name` automatically for any legacy queries:

```sql
-- Drop the old default first so we can alter the column type.
ALTER TABLE public.players
  ALTER COLUMN name DROP DEFAULT,
  ALTER COLUMN name DROP NOT NULL;

-- Recreate as a stored generated column.
-- NOTE: Postgres does not support altering a plain column to a generated column
-- in-place; we must drop and re-add it.
ALTER TABLE public.players DROP COLUMN IF EXISTS name;

ALTER TABLE public.players
  ADD COLUMN name TEXT GENERATED ALWAYS AS (
    TRIM(first_name || ' ' || last_name)
  ) STORED;
```

> **Skip Section 3** if you prefer to keep `name` as a plain column that
> you no longer write to. The Flutter app no longer writes `name` as of v1.8.

---

## Section 4 — Update link_player_to_user RPC (replaces previous version)

Fixes the missing team_members row when linking a player to a user account.

```sql
CREATE OR REPLACE FUNCTION public.link_player_to_user(
  p_team_id      UUID,
  p_player_id    UUID,
  p_player_email TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Resolve user by email
  SELECT id INTO v_user_id
  FROM public.users
  WHERE email = p_player_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No user found with email %', p_player_email;
  END IF;

  -- Verify the caller is an owner/coach/manager of this team
  IF NOT EXISTS (
    SELECT 1 FROM public.team_members
    WHERE team_id = p_team_id
      AND user_id = auth.uid()
      AND role IN ('owner', 'coach', 'team_manager')
  ) THEN
    RAISE EXCEPTION 'Caller is not authorized to link players on this team';
  END IF;

  -- Link the player record to the resolved user
  UPDATE public.players
  SET user_id = v_user_id
  WHERE id = p_player_id
    AND team_id = p_team_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player % not found on team %', p_player_id, p_team_id;
  END IF;

  -- Upsert team_members so the linked user can access the team
  INSERT INTO public.team_members (team_id, user_id, role, player_id)
  VALUES (p_team_id, v_user_id, 'player', p_player_id)
  ON CONFLICT (team_id, user_id)
  DO UPDATE SET
    role      = EXCLUDED.role,
    player_id = EXCLUDED.player_id;
END;
$$;
```

If the `ON CONFLICT` clause fails, add the unique constraint first:

```sql
ALTER TABLE public.team_members
  ADD CONSTRAINT team_members_team_user_unique UNIQUE (team_id, user_id);
```

---

## Section 5 — Manually add a user to team_members as a player

```sql
INSERT INTO public.team_members (team_id, user_id, role)
VALUES (
  'd4d4bc5e-5ae1-4af0-9b8b-fcc3eed6edb0',
  '58842965-a235-4ea6-8ff7-a33e727630e6',
  'player'
)
ON CONFLICT (team_id, user_id)
DO UPDATE SET role = 'player';
```

---

## Section 6 — add_member_to_team RPC (create or replace)

Adds an existing user to a team by email. Caller must be owner/coach/team_manager.

```sql
CREATE OR REPLACE FUNCTION public.add_member_to_team(
  p_team_id UUID,
  p_email   TEXT,
  p_role    TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Resolve user by email from public.users (populated by handle_new_user trigger)
  SELECT id INTO v_user_id
  FROM public.users
  WHERE email = LOWER(TRIM(p_email))
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No Apex On Deck account found for email: %', p_email;
  END IF;

  -- Verify the caller is an owner/coach/manager of this team
  IF NOT EXISTS (
    SELECT 1 FROM public.team_members
    WHERE team_id = p_team_id
      AND user_id = auth.uid()
      AND role IN ('owner', 'coach', 'team_manager')
  ) THEN
    RAISE EXCEPTION 'You are not authorized to add members to this team';
  END IF;

  -- Validate role
  IF p_role NOT IN ('coach', 'player', 'team_parent', 'team_manager') THEN
    RAISE EXCEPTION 'Invalid role: %', p_role;
  END IF;

  -- Insert or update team membership
  INSERT INTO public.team_members (team_id, user_id, role)
  VALUES (p_team_id, v_user_id, p_role)
  ON CONFLICT (team_id, user_id)
  DO UPDATE SET role = EXCLUDED.role;
END;
$$;
```

---

## Section 7 — Verification

```sql
-- Confirm columns exist and data migrated correctly
SELECT id, first_name, last_name, name
FROM public.players
LIMIT 20;

-- Confirm team_members row created after linking
SELECT tm.*, p.first_name, p.last_name
FROM public.team_members tm
LEFT JOIN public.players p ON p.id = tm.player_id
WHERE tm.team_id = '<your-team-id>'
ORDER BY tm.created_at DESC
LIMIT 10;
```
