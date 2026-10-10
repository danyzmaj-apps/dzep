-- omp sessions followed on the iPhone's Lock Screen (Live Activities,
-- docs/ARCHITECTURE.md). Each activity has its own APNs push token; the
-- phone registers it for its omp session, and functions/push sends that
-- session's state changes to it through the relay. A state only: no text
-- travels in these pushes.

create table public.activity_tokens (
  token text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- The omp session's key (`kitty-<pid>/<window id>` or `pid:<pid>`).
  session text not null,
  updated_at timestamptz not null default now()
);

create index activity_tokens_user_session on public.activity_tokens (user_id, session);

-- Written by functions/push only (service role); no policies.
alter table public.activity_tokens enable row level security;
