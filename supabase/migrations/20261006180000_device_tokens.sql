-- Long-lived per-device tokens for capture paths that can't hold a Supabase
-- session: the iPhone's Siri / Action Button intent. The app mints a random
-- token at sign-in, stores it on the phone and registers only its SHA-256
-- here; the add-idea edge function swaps it for the user id.
create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  token_hash text not null unique,
  label text not null default '',
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

alter table public.device_tokens enable row level security;

create policy "own tokens: read" on public.device_tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own tokens: insert" on public.device_tokens
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own tokens: delete" on public.device_tokens
  for delete to authenticated using (user_id = (select auth.uid()));
