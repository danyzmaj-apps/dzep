-- delete_my_account and the reviewer demo account's access (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000d', 'reviewer@x.dzep.invalid', '{"provider": "email", "dzep_demo": true}');

-- Signs in as [id] the way PostgREST does for a request with that user's token.
create function pg_temp.sign_in(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', id, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.sign_out() returns void language sql as $$
  select set_config('role', 'none', true), set_config('request.jwt.claims', '', true)
$$;

-- What each account has: an idea, a chat with a message, a device token, a
-- phone, a followed session and a session of its own.
insert into public.ideas (id, user_id, title)
  select gen_random_uuid(), u, 'x' from unnest(array['00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000d']::uuid[]) u;
insert into public.chats (id, user_id) values
  ('00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000000cd', '00000000-0000-0000-0000-00000000000d');
insert into public.chat_messages (chat_id, user_id, role) values
  ('00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-00000000000a', 'user'),
  ('00000000-0000-0000-0000-0000000000cd', '00000000-0000-0000-0000-00000000000d', 'user');
insert into public.device_tokens (user_id, token_hash) values
  ('00000000-0000-0000-0000-00000000000a', 'owner-device'), ('00000000-0000-0000-0000-00000000000d', 'demo-device');
insert into public.push_devices (token, user_id, key) values
  ('owner-phone', '00000000-0000-0000-0000-00000000000a', 'k'), ('demo-phone', '00000000-0000-0000-0000-00000000000d', 'k');
insert into public.activity_tokens (token, user_id, session) values
  ('owner-activity', '00000000-0000-0000-0000-00000000000a', 's'), ('demo-activity', '00000000-0000-0000-0000-00000000000d', 's');
insert into auth.sessions (id, user_id) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-0000000005d1', '00000000-0000-0000-0000-00000000000d'),
  ('00000000-0000-0000-0000-0000000005d2', '00000000-0000-0000-0000-00000000000d');
insert into auth.refresh_tokens (token, user_id, session_id) values
  ('demo-refresh', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000005d1');
-- Two reviewer codes (App Store, Play), a phone code the demo made for itself.
insert into public.pairing_codes (id, code_hash, user_id, created_by, reusable, label, expires_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'app-store', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, 'App Store review', now() + interval '30 days'),
  ('00000000-0000-0000-0000-0000000000a2', 'play', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, 'Play review', now() + interval '30 days'),
  ('00000000-0000-0000-0000-0000000000a3', 'demo-phone', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000d', false, '', now() + interval '10 minutes');

create function pg_temp.rows_of(owner uuid) returns bigint language sql as $$
  select (select count(*) from public.ideas where user_id = owner)
       + (select count(*) from public.chats where user_id = owner)
       + (select count(*) from public.chat_messages where user_id = owner)
       + (select count(*) from public.device_tokens where user_id = owner)
       + (select count(*) from public.push_devices where user_id = owner)
       + (select count(*) from public.activity_tokens where user_id = owner)
$$;

-- Reviewer access while codes work.
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000d');
select ok(public.reviewer_access_active(), 'the demo account has access while a reviewer code works');
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');
select ok(public.reviewer_access_active(), 'the owner always has access');

-- The demo account "deleting itself" empties it and keeps the account and the owner's codes.
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000d');
select lives_ok('select public.delete_my_account()', 'the demo account can delete its account');
select pg_temp.sign_out();
select is(pg_temp.rows_of('00000000-0000-0000-0000-00000000000d'), 0::bigint, 'its rows are gone');
select ok(exists (select 1 from auth.users where id = '00000000-0000-0000-0000-00000000000d'), 'the demo account stays');
select is((select count(*) from public.pairing_codes where reusable), 2::bigint, 'the reviewer codes survive');
select ok(not exists (select 1 from public.pairing_codes where code_hash = 'demo-phone'), 'its own phone code is gone');
select is(pg_temp.rows_of('00000000-0000-0000-0000-00000000000a'), 6::bigint, 'the owner''s rows are untouched');
select is(public.redeem_pairing_code('app-store', null), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'the next reviewer still signs in with the same code');

-- Revoking one of two reviewer codes keeps the demo signed in; revoking the last ends its sessions.
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');
update public.pairing_codes set revoked_at = now() where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.sign_out();
select is((select count(*) from auth.sessions where user_id = '00000000-0000-0000-0000-00000000000d'), 2::bigint,
  'with a code left, the demo stays signed in');
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');
update public.pairing_codes set revoked_at = now() where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.sign_out();
select is((select count(*) from auth.sessions where user_id = '00000000-0000-0000-0000-00000000000d'), 0::bigint,
  'revoking the last code signs the demo out everywhere');
select is((select count(*) from auth.refresh_tokens where user_id = '00000000-0000-0000-0000-00000000000d'), 0::bigint,
  'its refresh tokens go with its sessions');
select is((select count(*) from auth.sessions where user_id = '00000000-0000-0000-0000-00000000000a'), 1::bigint,
  'the owner''s session stays');
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000d');
select ok(not public.reviewer_access_active(), 'the demo account has no access any more');

-- A code running out ends the demo's sessions on the next scheduled sweep.
select pg_temp.sign_out();
insert into public.pairing_codes (code_hash, user_id, created_by, reusable, expires_at) values
  ('new', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, now() + interval '1 day');
insert into auth.sessions (id, user_id) values ('00000000-0000-0000-0000-0000000005d3', '00000000-0000-0000-0000-00000000000d');
select is(public.end_idle_demo_sessions(), 0, 'nothing ends while a code works');
update public.pairing_codes set expires_at = now() - interval '1 second' where code_hash = 'new';
select is(public.end_idle_demo_sessions(), 1, 'the sweep ends the sessions once the code ran out');
select ok(exists (select 1 from cron.job where jobname = 'dzep-demo-sessions' and command like '%end_idle_demo_sessions%'),
  'the sweep is scheduled');

-- Anyone else's account goes, with everything in it.
select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');
select lives_ok('select public.delete_my_account()', 'the owner can delete their account');
select pg_temp.sign_out();
select ok(not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-00000000000a'), 'the owner is gone');
select is(pg_temp.rows_of('00000000-0000-0000-0000-00000000000a'), 0::bigint, 'with every row of theirs');

select throws_ok('select public.delete_my_account()', 'not signed in', 'no account to delete without a sign-in');

select * from finish();
rollback;
