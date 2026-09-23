-- Snapchat-style snaps: a photo/video is "tap to view" once per recipient,
-- then shows as Opened, unless someone saves it in chat, which keeps it
-- viewable for everyone. Applied via the CLI; schema.sql includes it.

alter table public.messages
  add column saved_by uuid references public.profiles (id) on delete set null,
  add column saved_at timestamptz;

-- History from before this existed stays visible: treat it as saved.
update public.messages
set saved_at = created_at, saved_by = sender_id
where kind in ('photo', 'video') and saved_at is null;

-- Who has opened which snap.
create table public.snap_views (
  message_id  uuid not null references public.messages (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  opened_at   timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.snap_views enable row level security;
create policy "members read snap views"
  on public.snap_views for select to authenticated
  using (exists (
    select 1 from public.messages m
    where m.id = message_id and public.is_member(m.conversation_id)
  ));
-- Writes only through the functions below.

-- Mark a snap you received as opened. Idempotent.
create function public.mark_snap_opened(mid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (
    select 1 from public.messages m
    where m.id = mid
      and m.kind in ('photo', 'video')
      and m.sender_id <> me
      and public.is_member(m.conversation_id)
  ) then
    raise exception 'not a snap you received';
  end if;
  insert into public.snap_views (message_id, user_id) values (mid, me)
  on conflict do nothing;
end;
$$;

-- Save a snap in chat, or unsave one you saved. Any member can save.
create function public.set_snap_saved(mid uuid, saved boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (
    select 1 from public.messages m
    where m.id = mid and m.kind in ('photo', 'video') and public.is_member(m.conversation_id)
  ) then
    raise exception 'not a snap in your chats';
  end if;

  if saved then
    update public.messages set saved_by = me, saved_at = now()
    where id = mid and saved_at is null;
  else
    update public.messages set saved_by = null, saved_at = null
    where id = mid and saved_by = me;
  end if;
end;
$$;

-- Senders see "Opened" live; everyone sees saves live (messages UPDATEs are
-- already published since the table is in the publication).
alter publication supabase_realtime add table public.snap_views;
