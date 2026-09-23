-- Emoji reactions: one per person per message (reacting again replaces it).
-- Applied via the CLI; schema.sql includes it.
create table public.message_reactions (
  message_id  uuid not null references public.messages (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  emoji       text not null check (char_length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.message_reactions enable row level security;

-- Readable by the conversation's members.
create policy "members read reactions"
  on public.message_reactions for select to authenticated
  using (exists (
    select 1 from public.messages m
    where m.id = message_id and public.is_member(m.conversation_id)
  ));

-- You react as yourself, only in conversations you're in.
create policy "members react as themselves"
  on public.message_reactions for insert to authenticated
  with check (user_id = auth.uid() and exists (
    select 1 from public.messages m
    where m.id = message_id and public.is_member(m.conversation_id)
  ));
create policy "you change your own reaction"
  on public.message_reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "you remove your own reaction"
  on public.message_reactions for delete to authenticated
  using (user_id = auth.uid());

alter publication supabase_realtime add table public.message_reactions;
