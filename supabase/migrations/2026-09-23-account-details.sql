-- Birthday and mobile number. NOT on profiles: every signed-in user can read
-- profiles (that's how search works), and these are nobody else's business.
-- Only you can read or write your row. Applied via the CLI; in schema.sql.
create table public.account_details (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  birthday    date check (birthday > '1900-01-01'),
  -- Digits with an optional leading +; formatting is the app's job.
  phone       text check (phone ~ '^\+?[0-9]{7,15}$'),
  updated_at  timestamptz not null default now()
);

alter table public.account_details enable row level security;
create policy "only you see and edit your account details"
  on public.account_details for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
