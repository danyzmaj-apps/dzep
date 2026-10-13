-- One row per idea. The app writes ids itself (uuid v4) so it can save offline
-- and sync later; deletes are soft (deleted_at) so other Macs learn about them.
create table public.ideas (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null default '',
  notes text not null default '',
  project text not null default '',
  status text not null default 'inbox'
    check (status in ('inbox', 'building', 'shipped', 'dropped')),
  device text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- The pull cursor: "everything of mine changed since X".
create index ideas_user_updated on public.ideas (user_id, updated_at);

-- updated_at is the server's clock, never the client's, so the cursor is sound.
create function public.ideas_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger ideas_touch before insert or update on public.ideas
for each row execute function public.ideas_touch();

alter table public.ideas enable row level security;

create policy "own ideas: read" on public.ideas
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own ideas: insert" on public.ideas
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own ideas: update" on public.ideas
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Live updates from the other Macs.
alter publication supabase_realtime add table public.ideas;
