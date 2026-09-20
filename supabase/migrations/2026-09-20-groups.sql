-- Group chats. The tables already had is_group / name / conversation_members;
-- this adds the two operations and puts membership on realtime.
-- Run once in the SQL editor. (schema.sql includes it for fresh projects.)

-- Create a group with yourself plus some of your friends. Only accepted
-- friends can be added — enforced here, not in the app.
create function public.create_group(group_name text, member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me      uuid := auth.uid();
  cid     uuid;
  others  uuid[];
  outsider uuid;
begin
  if me is null then raise exception 'not signed in'; end if;

  if char_length(btrim(group_name)) not between 1 and 40 then
    raise exception 'group name must be 1–40 characters';
  end if;

  -- distinct, and never yourself
  select array_agg(distinct m) into others
  from unnest(member_ids) as m
  where m <> me;

  if others is null or cardinality(others) < 1 then
    raise exception 'a group needs at least one other person';
  end if;

  -- everyone must be an accepted friend
  select m into outsider
  from unnest(others) as m
  where not exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.user_id = me and f.friend_id = m) or (f.user_id = m and f.friend_id = me))
  )
  limit 1;
  if outsider is not null then
    raise exception 'can only add friends to a group';
  end if;

  insert into public.conversations (is_group, name, created_by)
  values (true, btrim(group_name), me)
  returning id into cid;

  insert into public.conversation_members (conversation_id, user_id)
  select cid, m from unnest(others || me) as m;

  return cid;
end;
$$;

-- Leave a group. The last one out turns the lights off.
create function public.leave_group(cid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;

  delete from public.conversation_members m
  using public.conversations c
  where m.conversation_id = cid
    and m.user_id = me
    and c.id = cid
    and c.is_group;

  if not found then raise exception 'not a member of that group'; end if;

  delete from public.conversations c
  where c.id = cid
    and not exists (select 1 from public.conversation_members where conversation_id = cid);
end;
$$;

-- So a group someone adds you to shows up without a pull-to-refresh.
alter publication supabase_realtime add table public.conversation_members;
