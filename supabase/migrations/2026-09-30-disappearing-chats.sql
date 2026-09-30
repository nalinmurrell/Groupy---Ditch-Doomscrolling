-- Snapchat-style disappearing chats. A text disappears once every other
-- member has seen it and left the chat, unless someone saved it. Applied
-- via the CLI; schema.sql includes it.

-- Everything already sent stays forever: only messages from now on can
-- disappear. (A flag, not "saved", so old history doesn't all turn grey.)
alter table public.messages
  add column ephemeral boolean not null default true;
update public.messages set ephemeral = false;

-- Saving now works for any message, texts included.
create or replace function public.set_snap_saved(mid uuid, saved boolean)
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
    where m.id = mid and public.is_member(m.conversation_id)
  ) then
    raise exception 'not a message in your chats';
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

-- Called when you close a chat (or the app goes to the background with it
-- open): everything others sent you there counts as seen, then any unsaved
-- text that every other member has now seen is deleted for everyone.
create function public.leave_chat(cid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if not public.is_member(cid) then raise exception 'not a member of that chat'; end if;

  insert into public.snap_views (message_id, user_id)
  select m.id, me
  from public.messages m
  where m.conversation_id = cid and m.kind = 'text' and m.sender_id <> me
  on conflict do nothing;

  delete from public.messages m
  where m.conversation_id = cid
    and m.kind = 'text'
    and m.ephemeral
    and m.saved_at is null
    and not exists (
      select 1 from public.conversation_members cm
      where cm.conversation_id = cid
        and cm.user_id <> m.sender_id
        and not exists (
          select 1 from public.snap_views v
          where v.message_id = m.id and v.user_id = cm.user_id
        )
    );
end;
$$;
