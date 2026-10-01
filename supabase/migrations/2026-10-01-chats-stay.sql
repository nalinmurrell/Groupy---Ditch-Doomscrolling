-- Chats no longer disappear (reverses 2026-09-30's Snapchat behaviour at
-- Nalin's request). New messages are permanent, existing ones become
-- permanent, and leave_chat stops deleting anything. It still records that
-- you've seen others' texts (harmless, and useful for read receipts later).
-- Done server-side so older builds, which still call leave_chat, stop
-- deleting too.
alter table public.messages alter column ephemeral set default false;
update public.messages set ephemeral = false where ephemeral;

create or replace function public.leave_chat(cid uuid)
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
  where m.conversation_id = cid and m.kind in ('text', 'audio') and m.sender_id <> me
  on conflict do nothing;
end;
$$;
