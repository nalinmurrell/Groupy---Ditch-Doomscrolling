-- Who's in a chat right now (the member pills above the composer). Clients
-- join a private Realtime channel "chat:<conversation id>" and track
-- presence on it; these policies make sure only members of that
-- conversation can join, see who's there, or announce themselves.
create policy "members see who's in their chats"
  on realtime.messages for select to authenticated
  using (
    realtime.messages.extension = 'presence'
    and split_part(realtime.topic(), ':', 1) = 'chat'
    and split_part(realtime.topic(), ':', 2) in (
      select conversation_id::text from public.conversation_members
      where user_id = auth.uid()
    )
  );

create policy "members show up in their chats"
  on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'presence'
    and split_part(realtime.topic(), ':', 1) = 'chat'
    and split_part(realtime.topic(), ':', 2) in (
      select conversation_id::text from public.conversation_members
      where user_id = auth.uid()
    )
  );
