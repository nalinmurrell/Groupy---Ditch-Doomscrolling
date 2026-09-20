-- Add members to an existing group. Run once in the SQL editor.
-- (schema.sql includes it for fresh projects.)

-- Add friends to a group you're in. Same rule as creating one: only your
-- accepted friends, checked here. Anyone already in is skipped.
create function public.add_group_members(cid uuid, member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me       uuid := auth.uid();
  newcomers uuid[];
  outsider uuid;
begin
  if me is null then raise exception 'not signed in'; end if;

  if not exists (
    select 1 from public.conversations c
    join public.conversation_members m on m.conversation_id = c.id
    where c.id = cid and c.is_group and m.user_id = me
  ) then
    raise exception 'not a member of that group';
  end if;

  select array_agg(distinct m) into newcomers
  from unnest(member_ids) as m
  where m <> me
    and not exists (
      select 1 from public.conversation_members x
      where x.conversation_id = cid and x.user_id = m
    );

  if newcomers is null then return; end if;

  select m into outsider
  from unnest(newcomers) as m
  where not exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.user_id = me and f.friend_id = m) or (f.user_id = m and f.friend_id = me))
  )
  limit 1;
  if outsider is not null then
    raise exception 'can only add friends to a group';
  end if;

  insert into public.conversation_members (conversation_id, user_id)
  select cid, m from unnest(newcomers) as m
  on conflict do nothing;
end;
$$;
