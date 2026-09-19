-- Friend requests: friendships become request → accept instead of one-sided.
-- Run once in the SQL editor on the existing project. (schema.sql already
-- includes all of this for a fresh project.)

alter table public.friendships
  add column status text not null default 'pending'
    check (status in ('pending', 'accepted'));

-- Rows that predate requests were one-sided adds; treat them as accepted
-- rather than surprising anyone with a request they never sent.
update public.friendships set status = 'accepted';

-- One row per pair, whichever direction it was sent in.
create unique index friendships_pair_idx
  on public.friendships (least(user_id, friend_id), greatest(user_id, friend_id));

-- Both parties can see the row; all writes go through the functions below.
drop policy "read own friendships"   on public.friendships;
drop policy "add own friendships"    on public.friendships;
drop policy "remove own friendships" on public.friendships;

create policy "parties read friendships"
  on public.friendships for select to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());

-- Returns the resulting status: 'pending' (request sent / already sent) or
-- 'accepted' (already friends, or they had asked first so it's mutual now).
create function public.send_friend_request(other_user uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  existing public.friendships%rowtype;
begin
  if me is null then raise exception 'not signed in'; end if;
  if other_user = me then raise exception 'cannot friend yourself'; end if;

  select * into existing from public.friendships
  where (user_id = me and friend_id = other_user)
     or (user_id = other_user and friend_id = me);

  if found then
    if existing.status = 'accepted' then
      return 'accepted';
    elsif existing.user_id = other_user then
      -- They asked first. Two people wanting the same thing is an accept.
      perform public.accept_friend_request(other_user);
      return 'accepted';
    else
      return 'pending';
    end if;
  end if;

  insert into public.friendships (user_id, friend_id, status)
  values (me, other_user, 'pending');
  return 'pending';
end;
$$;

create function public.accept_friend_request(other_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;

  update public.friendships
  set status = 'accepted'
  where user_id = other_user and friend_id = me and status = 'pending';

  if not found then raise exception 'no pending request from that user'; end if;

  -- Being friends means having a thread.
  perform public.get_or_create_dm(other_user);
end;
$$;

-- Decline, cancel, or unfriend — same thing from the table's point of view.
create function public.remove_friendship(other_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  delete from public.friendships
  where (user_id = me and friend_id = other_user)
     or (user_id = other_user and friend_id = me);
end;
$$;

-- Requests should appear without a pull-to-refresh.
alter publication supabase_realtime add table public.friendships;
