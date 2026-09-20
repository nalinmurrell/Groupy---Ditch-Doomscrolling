-- Pinned chats: per member, at most three. Run once in the SQL editor.

alter table public.conversation_members
  add column pinned_at timestamptz;

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
