-- Voice notes. Stored like snaps (photo_path holds snaps/<cid>/<uuid>.m4a)
-- but they behave like texts: they disappear once everyone's seen the chat,
-- unless someone saves them.
alter table public.messages drop constraint messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text', 'photo', 'video', 'audio'));

alter table public.messages drop constraint messages_check;
alter table public.messages add constraint messages_check check (
  (kind = 'text'  and body is not null and photo_path is null) or
  (kind in ('photo', 'video', 'audio') and photo_path is not null and body is null)
);

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

  delete from public.messages m
  where m.conversation_id = cid
    and m.kind in ('text', 'audio')
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
