-- Push notifications. Run once in the SQL editor; deploy the
-- `notify` edge function too. (schema.sql includes it for fresh projects.)

-- Where to reach each signed-in device. A token belongs to whoever last
-- signed in on that device; signing out deletes it.
create table public.device_tokens (
  token        text primary key,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  -- Debug builds talk to Apple's sandbox APNs, TestFlight/App Store to production.
  environment  text not null check (environment in ('sandbox', 'production')),
  updated_at   timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;
create policy "you manage your own device tokens"
  on public.device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Every new message pings the edge function, which fans out to the other
-- members' devices. The anon key here is the public client key; the
-- function re-reads the message from the database and never trusts the
-- payload, so a forged call can at most re-send a real notification.
create extension if not exists pg_net with schema extensions;

create function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url     := 'https://xbvmwfvriwhtrotefirx.supabase.co/functions/v1/notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhidm13ZnZyaXdodHJvdGVmaXJ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1MTg3NzEsImV4cCI6MjEwNTA5NDc3MX0.gqgetfH6LoWw63JLKR9aCWk1FsOVFM0YAhVj0SUucho'
    ),
    body    := jsonb_build_object(
      'type', 'INSERT',
      'table', 'messages',
      'record', jsonb_build_object('id', new.id)
    )
  );
  return new;
end;
$$;

create trigger notify_new_message
  after insert on public.messages
  for each row execute function public.notify_new_message();
