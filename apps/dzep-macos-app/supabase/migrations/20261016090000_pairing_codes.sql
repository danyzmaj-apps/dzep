-- Phones sign in only with a code from the Mac (functions/pair), never with
-- GitHub. A code is a random string the Mac shows in a QR (inside a setup
-- link); only its SHA-256 is kept here. Redeeming it makes a fresh magic-link
-- token for the code's user, which the phone turns into its own session.
--
-- Two kinds:
--   * a phone's code (Settings → Set up phone…): single use, 10 minutes, for
--     the signed-in user;
--   * a reviewer code (Settings → Reviewer access): reusable until it expires
--     or is revoked, for a separate demo account on this server, so App Store
--     and Play reviewers can sign in without the owner's Mac. The demo account
--     is made by the function with app_metadata.dzep_demo = true; it has no
--     access to the owner's rows (every table is own-rows only).
create table public.pairing_codes (
  id uuid primary key default gen_random_uuid(),
  -- Who the code signs in.
  user_id uuid not null references auth.users (id) on delete cascade,
  -- Who made it (the owner, also for a reviewer code): the one who lists and
  -- revokes it.
  created_by uuid not null references auth.users (id) on delete cascade,
  code_hash text not null unique,
  reusable boolean not null default false,
  label text not null default '',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

create index pairing_codes_created_by on public.pairing_codes (created_by);
create index pairing_codes_user_id on public.pairing_codes (user_id);

alter table public.pairing_codes enable row level security;

-- Clients see their own codes without the hashes, and can only revoke them;
-- codes are made and redeemed by functions/pair (service role).
revoke all on public.pairing_codes from anon, authenticated;
grant select (id, user_id, created_by, reusable, label, expires_at, created_at, last_used_at, revoked_at)
  on public.pairing_codes to authenticated;
grant update (revoked_at) on public.pairing_codes to authenticated;

create policy "own codes: read" on public.pairing_codes
  for select to authenticated using (created_by = (select auth.uid()));
create policy "own codes: revoke" on public.pairing_codes
  for update to authenticated using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));

-- Failed redeems per caller, for a cheap throttle. The codes carry 140 random
-- bits, so guessing is hopeless anyway; this only keeps a flood cheap.
create table public.pairing_failures (
  ip text not null,
  at timestamptz not null default now()
);

create index pairing_failures_ip_at on public.pairing_failures (ip, at);

-- No policies: only the service role.
alter table public.pairing_failures enable row level security;

-- Uses a code, all in one statement so two phones racing on a single-use
-- code can't both win: {"user_id"} when it works, {"error": "invalid"} for a
-- code that doesn't exist, expired, was revoked or (single use) was used,
-- {"error": "throttled"} after 10 failures from the same caller in 10 minutes.
create function public.redeem_pairing_code(p_hash text, p_ip text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid;
begin
  if (select count(*) from public.pairing_failures f
      where f.ip = p_ip and f.at > now() - interval '10 minutes') >= 10 then
    return '{"error": "throttled"}'::jsonb;
  end if;
  update public.pairing_codes c set last_used_at = now()
    where c.code_hash = p_hash
      and c.revoked_at is null
      and c.expires_at > now()
      and (c.reusable or c.last_used_at is null)
    returning c.user_id into uid;
  if uid is null then
    delete from public.pairing_failures f where f.at < now() - interval '1 hour';
    insert into public.pairing_failures (ip) values (p_ip);
    return '{"error": "invalid"}'::jsonb;
  end if;
  return jsonb_build_object('user_id', uid);
end $$;

revoke execute on function public.redeem_pairing_code(text, text) from public, anon, authenticated;
grant execute on function public.redeem_pairing_code(text, text) to service_role;

-- The server's demo account (for reviewer codes), if it has one.
create function public.pairing_demo_user() returns uuid
language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u
  where u.raw_app_meta_data ->> 'dzep_demo' = 'true'
  order by u.created_at
  limit 1
$$;

revoke execute on function public.pairing_demo_user() from public, anon, authenticated;
grant execute on function public.pairing_demo_user() to service_role;

-- The private-server hook, now also letting in the demo account that
-- functions/pair makes. Only the service role can set app_metadata, so a
-- stranger's sign-up can't claim to be it. The demo account doesn't count as
-- "the first account": an owner who deleted theirs can still sign in again.
create or replace function public.before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if event -> 'user' -> 'app_metadata' ->> 'dzep_demo' = 'true'
    or not exists (
      select 1 from auth.users u where coalesce(u.raw_app_meta_data ->> 'dzep_demo', '') <> 'true'
    )
    or exists (select 1 from public.allowed_signups a where a.email = lower(event -> 'user' ->> 'email'))
  then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This Džep server is private. Its owner can let you in by adding your email to allowed_signups.'
  ));
end $$;
