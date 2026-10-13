-- Todos live next to ideas: same sync, same capture paths. A todo is
-- open (done_at null) or done; status/project stay at their defaults.
alter table public.ideas
  add column kind text not null default 'idea' check (kind in ('idea', 'todo')),
  add column done_at timestamptz;
