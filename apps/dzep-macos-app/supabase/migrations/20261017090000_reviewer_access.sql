-- The reviewer demo account and sign-up, tightened (supabase/tests/*.sql).

-- The demo account deleting "itself" (App and Play reviewers try in-app
-- account deletion) empties it instead: its rows go, the account stays.
-- Deleting it would cascade to every reviewer code, including the ones
-- already handed to App Store Connect and Play, and lock out the next review.
-- Everyone else's account goes, with everything in it, as before.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from auth.users u where u.id = uid and u.raw_app_meta_data ->> 'dzep_demo' = 'true') then
    delete from public.ideas where user_id = uid;
    delete from public.chat_messages where user_id = uid;
    delete from public.chats where user_id = uid;
    delete from public.device_tokens where user_id = uid;
    delete from public.push_devices where user_id = uid;
    delete from public.activity_tokens where user_id = uid;
    -- Phone codes it made for itself; reviewer codes are the owner's.
    delete from public.pairing_codes where user_id = uid and not reusable;
    return;
  end if;
  delete from auth.users where id = uid;
end $$;

-- Sign-up only through a provider that proves who you are (GitHub). Email
-- sign-up is off in config.toml, but a project set up some other way may
-- still allow it, and then anyone could claim an allowed (or, before the
-- owner's first sign-in, any) address without owning it. The demo account,
-- made by functions/pair with the service role, is the one email account.
create or replace function public.before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if event -> 'user' -> 'app_metadata' ->> 'dzep_demo' = 'true' then
    return '{}'::jsonb;
  end if;
  if coalesce(event -> 'user' -> 'app_metadata' ->> 'provider', 'email') in ('email', 'phone', 'anonymous') then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'This Džep server signs in with GitHub only.'
    ));
  end if;
  if not exists (
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

-- Whether the signed-in user may still use the server: always, except the
-- demo account once none of its reviewer codes works (revoked, run out, or
-- the owner's account deleted). functions/ask and functions/pair check it.
create function public.reviewer_access_active() returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
      select 1 from auth.users u where u.id = (select auth.uid()) and u.raw_app_meta_data ->> 'dzep_demo' = 'true'
    )
    or exists (
      select 1 from public.pairing_codes c
      where c.user_id = (select auth.uid()) and c.reusable and c.revoked_at is null and c.expires_at > now()
    )
$$;

revoke execute on function public.reviewer_access_active() from public, anon;
grant execute on function public.reviewer_access_active() to authenticated;

-- Signs the demo account out everywhere once no reviewer code of it works:
-- a session made from a code (a magic link, then rotating refresh tokens)
-- would otherwise outlive the code. Access tokens already out stop working
-- with their session. Returns how many sessions ended.
create function public.end_idle_demo_sessions() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  ended integer;
begin
  with idle as (
    select u.id from auth.users u
    where u.raw_app_meta_data ->> 'dzep_demo' = 'true'
      and not exists (
        select 1 from public.pairing_codes c
        where c.user_id = u.id and c.reusable and c.revoked_at is null and c.expires_at > now()
      )
  ),
  gone as (
    delete from auth.sessions s using idle where s.user_id = idle.id returning 1
  )
  select count(*) into ended from gone;
  return ended;
end $$;

revoke execute on function public.end_idle_demo_sessions() from public, anon, authenticated;

-- Right away when a code is revoked or deleted (the owner deleting their
-- account deletes their codes) ...
create function public.pairing_codes_end_idle_demo_sessions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.end_idle_demo_sessions();
  return null;
end $$;

revoke execute on function public.pairing_codes_end_idle_demo_sessions() from public, anon, authenticated;

create trigger end_idle_demo_sessions
  after update of revoked_at or delete on public.pairing_codes
  for each statement execute function public.pairing_codes_end_idle_demo_sessions();

-- ... and within 10 minutes of the last one running out.
select cron.schedule('dzep-demo-sessions', '*/10 * * * *', 'select public.end_idle_demo_sessions()');

-- The pairing throttle counts failures per caller only when the platform
-- names the caller (functions/pair passes null otherwise): one shared bucket
-- for every unknown caller would let ten bad tries lock out every phone.
create or replace function public.redeem_pairing_code(p_hash text, p_ip text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid;
begin
  if p_ip is not null and (select count(*) from public.pairing_failures f
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
    if p_ip is not null then
      delete from public.pairing_failures f where f.at < now() - interval '1 hour';
      insert into public.pairing_failures (ip) values (p_ip);
    end if;
    return '{"error": "invalid"}'::jsonb;
  end if;
  return jsonb_build_object('user_id', uid);
end $$;
