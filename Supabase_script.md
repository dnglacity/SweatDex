## Match Invites — v1.14 (ambiguous code fix)

The table and prior RPCs are already applied. Run only this to replace
`get_or_create_match_invite` (fixes ambiguous `code` column reference) and
`redeem_match_invite` (single-use, unchanged).

```sql
-- =============================================================================
-- RPC: get_or_create_match_invite  (replaces previous version)
-- Fix: qualify match_invites.code with table alias to resolve ambiguity with
-- the RETURNS TABLE output column also named "code".
-- =============================================================================
create or replace function public.get_or_create_match_invite(p_match_id uuid)
returns table(code character, expires_at timestamptz)
language plpgsql security definer as $$
declare
  v_team_id uuid;
  v_code    char(6);
  v_exp     timestamptz;
begin
  -- Resolve team and verify caller role.
  select m.team_id into v_team_id
  from public.matches m
  where m.id = p_match_id;

  if v_team_id is null then
    raise exception 'Match not found.';
  end if;

  if not exists (
    select 1 from public.team_members
    where team_id = v_team_id
      and user_id = auth.uid()
      and role in ('owner', 'coach', 'team_manager')
  ) then
    raise exception 'Not authorized to create match invites.';
  end if;

  -- Return existing active invite if still valid.
  select mi.code, mi.expires_at into v_code, v_exp
  from public.match_invites mi
  where mi.match_id = p_match_id
    and mi.is_active = true
    and mi.expires_at > now()
  order by mi.created_at desc
  limit 1;

  if v_code is not null then
    return query select v_code, v_exp;
    return;
  end if;

  -- Generate a unique 6-char alphanumeric code.
  loop
    v_code := upper(substring(md5(random()::text) from 1 for 6));
    exit when not exists (
      select 1 from public.match_invites mi
      where mi.code = v_code and mi.is_active = true  -- qualified to avoid OUTPUT column ambiguity
    );
  end loop;

  v_exp := now() + interval '7 days';

  insert into public.match_invites(match_id, code, created_by, expires_at)
  values (p_match_id, v_code, auth.uid(), v_exp);

  return query select v_code, v_exp;
end;
$$;

-- =============================================================================
-- RPC: redeem_match_invite  (replaces previous version)
-- Redeems a 6-char code and creates a mirrored match row for p_team_id.
-- Code is single-use: deactivated immediately after successful redemption.
-- =============================================================================
create or replace function public.redeem_match_invite(p_code text, p_team_id uuid)
returns table(out_match_id uuid, out_opponent_name text, out_match_date timestamptz)
language plpgsql security definer as $$
declare
  v_invite public.match_invites%rowtype;
  v_match  public.matches%rowtype;
  v_new_id uuid;
begin
  -- Verify caller is a coach/owner of the target team.
  if not exists (
    select 1 from public.team_members
    where team_id = p_team_id
      and user_id = auth.uid()
      and role in ('owner', 'coach', 'team_manager')
  ) then
    raise exception 'Not authorized to add matches to this team.';
  end if;

  -- Look up the invite.
  select * into v_invite
  from public.match_invites
  where code = upper(p_code)
    and is_active = true
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'Invalid or expired match code.';
  end if;

  -- Fetch the original match.
  select * into v_match from public.matches where id = v_invite.match_id;

  -- Cannot redeem your own match.
  if v_match.team_id = p_team_id then
    raise exception 'You cannot redeem an invite for your own match.';
  end if;

  -- Duplicate detection: same opponent and date already on schedule.
  if exists (
    select 1 from public.matches
    where team_id = p_team_id
      and match_date = v_match.match_date
      and opponent_name = v_match.my_team_name
  ) then
    raise exception 'This match is already on your schedule.';
  end if;

  -- Insert mirrored match (teams and home/away are flipped).
  insert into public.matches(team_id, my_team_name, opponent_name, match_date, is_home, notes)
  values (
    p_team_id,
    v_match.opponent_name,
    v_match.my_team_name,
    v_match.match_date,
    not v_match.is_home,
    v_match.notes
  )
  returning id into v_new_id;

  -- Deactivate the code — single-use.
  update public.match_invites
  set is_active = false
  where id = v_invite.id;

  return query select v_new_id, v_match.my_team_name::text, v_match.match_date;
end;
$$;
```
