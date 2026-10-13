-- Push notifications to the iPhone (functions/push, docs/ARCHITECTURE.md).
--
-- Each iPhone registers its APNs device token and a key it made itself;
-- this server encrypts every notification with that key and hands only the
-- ciphertext to the push relay (functions/relay, run by the app's publisher,
-- who holds the APNs key). The phone decrypts it (DzepPush extension).

create table public.push_devices (
  token text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- AES-256-GCM, base64; only this server and that phone know it.
  key text not null,
  label text not null default '',
  updated_at timestamptz not null default now()
);

-- Written by functions/push only (service role); no policies.
alter table public.push_devices enable row level security;

-- Reminders already pushed, by the remind_at they were pushed for: moving a
-- reminder pushes again, and a tick that overlaps another can't send twice.
create table public.push_sent (
  idea_id uuid not null references public.ideas (id) on delete cascade,
  remind_at timestamptz not null,
  primary key (idea_id, remind_at)
);
alter table public.push_sent enable row level security;

-- Where the scheduler calls functions/push and the secret it proves itself
-- with. functions/push fills it in on the first registration (it knows its
-- own URL), so no setup step has to.
create table public.push_config (
  id int primary key default 1 check (id = 1),
  url text not null,
  secret text not null
);
alter table public.push_config enable row level security;

-- Todos due now of users with a registered iPhone, not pushed yet. Only the
-- last 5 minutes (the scheduler runs every minute): an older one was either
-- pushed already or went off locally before the iPhone switched to push.
create view public.push_due with (security_invoker = true) as
select i.id, i.user_id, i.title, i.remind_at
from public.ideas i
where i.kind = 'todo'
  and i.done_at is null
  and i.deleted_at is null
  and i.remind_at <= now()
  and i.remind_at > now() - interval '5 minutes'
  and exists (select 1 from public.push_devices d where d.user_id = i.user_id)
  and not exists (select 1 from public.push_sent s where s.idea_id = i.id and s.remind_at = i.remind_at);

revoke all on public.push_due from anon, authenticated;

-- Claims what's due (marks it sent) and returns it: what functions/push sends.
create function public.claim_due_reminders()
returns table (id uuid, user_id uuid, title text, remind_at timestamptz)
language sql
security definer
set search_path = ''
as $$
  with claimed as (
    insert into public.push_sent (idea_id, remind_at)
    select d.id, d.remind_at from public.push_due d
    on conflict do nothing
    returning idea_id, remind_at
  )
  select c.idea_id, i.user_id, i.title, c.remind_at
  from claimed c join public.ideas i on i.id = c.idea_id;
$$;

revoke execute on function public.claim_due_reminders() from public, anon, authenticated;

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Every minute, and only when something is due: calls functions/push.
select cron.schedule(
  'dzep-push-reminders',
  '* * * * *',
  $job$
    select net.http_post(
      url := c.url || '/functions/v1/push',
      headers := jsonb_build_object('content-type', 'application/json', 'x-dzep-cron', c.secret),
      body := '{"action":"tick"}'::jsonb
    )
    from public.push_config c
    where exists (select 1 from public.push_due)
  $job$
);
