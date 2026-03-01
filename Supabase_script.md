# Supabase Script

## transfer_ownership RPC

Atomically demotes the current owner to coach and promotes the new owner,
preventing a window where a team has no owner if the second UPDATE would fail.

Run in the Supabase SQL editor:

```sql
CREATE OR REPLACE FUNCTION public.transfer_ownership(
  p_team_id           uuid,
  p_new_owner_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid;
BEGIN
  -- Resolve the calling user's public.users.id.
  SELECT id INTO v_caller_id
  FROM public.users
  WHERE user_id = auth.uid();

  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not logged in.';
  END IF;

  -- Verify the caller is the current owner.
  IF NOT EXISTS (
    SELECT 1 FROM public.team_members
    WHERE team_id = p_team_id
      AND user_id = v_caller_id
      AND role    = 'owner'
  ) THEN
    RAISE EXCEPTION 'Only the current owner can transfer ownership.';
  END IF;

  -- Verify the target is already a member of the team.
  IF NOT EXISTS (
    SELECT 1 FROM public.team_members
    WHERE team_id = p_team_id
      AND user_id = p_new_owner_user_id
  ) THEN
    RAISE EXCEPTION 'Target user is not a member of this team.';
  END IF;

  -- Both UPDATEs execute inside the same implicit transaction.
  -- If either fails the entire operation rolls back.
  UPDATE public.team_members
  SET role = 'coach'
  WHERE team_id = p_team_id
    AND user_id = v_caller_id;

  UPDATE public.team_members
  SET role = 'owner'
  WHERE team_id = p_team_id
    AND user_id = p_new_owner_user_id;
END;
$$;

-- Restrict execution to authenticated users only.
REVOKE ALL ON FUNCTION public.transfer_ownership(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_ownership(uuid, uuid) TO authenticated;
```
