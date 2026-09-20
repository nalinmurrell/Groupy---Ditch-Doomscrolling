-- ChatSnap schema. Run this once in the Supabase SQL editor.
-- Everything is locked down with row-level security; the app talks to the
-- database directly with the public anon key, so these policies ARE the
-- authorization layer.

-- ---------------------------------------------------------------------------
-- Profiles: one row per auth user, created by trigger on sign-up.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  username      text not null unique check (username ~ '^[a-z0-9_]{3,15}$'),
  display_name  text not null check (char_length(display_name) between 1 and 40),
  created_at    timestamptz not null default now()
);

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    new.raw_user_meta_data ->> 'username',
    new.raw_user_meta_data ->> 'display_name'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Friendships: request → accept. `user_id` asked, `friend_id` answers. One row
-- per pair regardless of direction. Writes go through the functions further
-- down, never directly.
-- ---------------------------------------------------------------------------
create table public.friendships (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  friend_id   uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

create unique index friendships_pair_idx
  on public.friendships (least(user_id, friend_id), greatest(user_id, friend_id));

-- ---------------------------------------------------------------------------
-- Conversations. `is_group` + `name` for groups, otherwise a DM.
-- ---------------------------------------------------------------------------
create table public.conversations (
  id          uuid primary key default gen_random_uuid(),
  is_group    boolean not null default false,
  name        text,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  joined_at        timestamptz not null default now(),
  -- This member's pin, if any. At most three per person (see set_pinned).
  pinned_at        timestamptz,
  primary key (conversation_id, user_id)
);

create index conversation_members_user_idx on public.conversation_members (user_id);

create table public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  sender_id        uuid not null references public.profiles (id) on delete cascade,
  kind             text not null check (kind in ('text', 'photo')),
  body             text,
  photo_path       text,
  created_at       timestamptz not null default now(),
  check (
    (kind = 'text'  and body is not null and photo_path is null) or
    (kind = 'photo' and photo_path is not null and body is null)
  )
);

create index messages_conversation_idx on public.messages (conversation_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Helpers. SECURITY DEFINER so policies can ask "am I a member?" without
-- recursing into the members table's own policy.
-- ---------------------------------------------------------------------------
create function public.is_member(cid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = cid and user_id = auth.uid()
  );
$$;

-- Find the DM between me and another user, creating it if needed.
create function public.get_or_create_dm(other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me  uuid := auth.uid();
  cid uuid;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if other_user = me then
    raise exception 'cannot open a DM with yourself';
  end if;

  select c.id into cid
  from public.conversations c
  where c.is_group = false
    and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = me)
    and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = other_user)
  limit 1;

  if cid is null then
    insert into public.conversations (is_group, created_by) values (false, me) returning id into cid;
    insert into public.conversation_members (conversation_id, user_id) values (cid, me), (cid, other_user);
  end if;

  return cid;
end;
$$;

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

create function public.set_pinned(cid uuid, pinned boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;

  if pinned and (
    select count(*) from public.conversation_members
    where user_id = me and pinned_at is not null and conversation_id <> cid
  ) >= 3 then
    raise exception 'you can pin up to 3 chats';
  end if;

  update public.conversation_members
  set pinned_at = case when pinned then now() else null end
  where conversation_id = cid and user_id = me;

  if not found then raise exception 'not a member of that chat'; end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.friendships          enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;

-- Anyone signed in can look people up; you can only edit yourself.
create policy "profiles are readable by signed-in users"
  on public.profiles for select to authenticated using (true);
create policy "you can update your own profile"
  on public.profiles for update to authenticated using (id = auth.uid());

-- Both parties see the row. No insert/update/delete policies on purpose —
-- the friend-request functions are the only writers.
create policy "parties read friendships"
  on public.friendships for select to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());

-- Conversations and their members are visible to members only.
create policy "members read conversations"
  on public.conversations for select to authenticated using (public.is_member(id));
create policy "members read membership"
  on public.conversation_members for select to authenticated using (public.is_member(conversation_id));

-- Messages: members read; you can only send as yourself, into rooms you're in.
create policy "members read messages"
  on public.messages for select to authenticated using (public.is_member(conversation_id));
create policy "members send messages as themselves"
  on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id));

-- ---------------------------------------------------------------------------
-- Storage: snaps live at  snaps/<conversation_id>/<uuid>.jpg
-- The folder name is the conversation, so membership gates the file.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('snaps', 'snaps', false);

create policy "members read snaps"
  on storage.objects for select to authenticated
  using (bucket_id = 'snaps' and public.is_member(((storage.foldername(name))[1])::uuid));

create policy "members upload snaps"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'snaps' and public.is_member(((storage.foldername(name))[1])::uuid));

-- ---------------------------------------------------------------------------
-- Realtime: the app subscribes to new messages.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.friendships;
alter publication supabase_realtime add table public.conversation_members;
