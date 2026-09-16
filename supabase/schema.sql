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
-- Friendships: directional. "I added you" — no request/accept step yet.
-- ---------------------------------------------------------------------------
create table public.friendships (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  friend_id   uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

-- ---------------------------------------------------------------------------
-- Conversations. DMs today; the same shape carries groups.
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

-- Your friend list is yours alone.
create policy "read own friendships"
  on public.friendships for select to authenticated using (user_id = auth.uid());
create policy "add own friendships"
  on public.friendships for insert to authenticated with check (user_id = auth.uid());
create policy "remove own friendships"
  on public.friendships for delete to authenticated using (user_id = auth.uid());

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
