-- Row level security: every account sees and changes only its own rows (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{"provider": "github"}');

create function pg_temp.sign_in(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', id, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.sign_out() returns void language sql as $$
  select set_config('role', 'none', true), set_config('request.jwt.claims', '', true)
$$;

-- B's rows, made by the server.
insert into public.ideas (id, user_id, title) values ('00000000-0000-0000-0000-0000000001b0', '00000000-0000-0000-0000-00000000000b', 'b');
insert into public.chats (id, user_id) values ('00000000-0000-0000-0000-0000000002b0', '00000000-0000-0000-0000-00000000000b');
insert into public.chat_messages (chat_id, user_id, role, content) values
  ('00000000-0000-0000-0000-0000000002b0', '00000000-0000-0000-0000-00000000000b', 'user', 'b');
insert into public.device_tokens (user_id, token_hash) values ('00000000-0000-0000-0000-00000000000b', 'b-device');
insert into public.push_devices (token, user_id, key) values ('b-phone', '00000000-0000-0000-0000-00000000000b', 'k');
insert into public.activity_tokens (token, user_id, session) values ('b-activity', '00000000-0000-0000-0000-00000000000b', 's');
insert into public.push_config (url, secret) values ('https://x.supabase.co', 'cron-secret');
insert into public.allowed_signups (email) values ('friend@example.com');
insert into public.pairing_failures (ip) values ('192.0.2.1');
insert into public.pairing_codes (id, code_hash, user_id, created_by, reusable, expires_at) values
  ('00000000-0000-0000-0000-0000000003b0', 'b-code', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', true, now() + interval '1 day');
insert into storage.objects (bucket_id, name) values ('chat', '00000000-0000-0000-0000-00000000000b/b.png');

select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');

-- Ideas, todos and notes.
select is((select count(*) from public.ideas), 0::bigint, 'B''s ideas are hidden from A');
select lives_ok($$insert into public.ideas (id, title) values ('00000000-0000-0000-0000-0000000001a0', 'a')$$, 'A adds an idea');
select is((select user_id from public.ideas), '00000000-0000-0000-0000-00000000000a'::uuid, 'which is A''s, and the only one A sees');
select throws_ok($$insert into public.ideas (id, user_id) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000b')$$,
  '42501', null, 'A cannot add an idea as B');
update public.ideas set title = 'hacked' where id = '00000000-0000-0000-0000-0000000001b0';
select throws_ok($$update public.ideas set user_id = '00000000-0000-0000-0000-00000000000b' where id = '00000000-0000-0000-0000-0000000001a0'$$,
  '42501', null, 'A cannot hand an idea to B');

-- Chats.
select is((select count(*) from public.chats) + (select count(*) from public.chat_messages), 0::bigint, 'B''s chats are hidden');
select throws_ok($$insert into public.chat_messages (chat_id, role, content) values ('00000000-0000-0000-0000-0000000002b0', 'user', 'x')$$,
  '42501', null, 'A cannot write into B''s chat');
select lives_ok($$insert into public.chats (id) values ('00000000-0000-0000-0000-0000000002a0')$$, 'A starts a chat');
select lives_ok($$insert into public.chat_messages (chat_id, role, content) values ('00000000-0000-0000-0000-0000000002a0', 'user', 'x')$$,
  'and writes into it');

-- Device tokens.
select is((select count(*) from public.device_tokens), 0::bigint, 'B''s device tokens are hidden');
delete from public.device_tokens where token_hash = 'b-device';

-- Server-only tables: nothing to see, nothing to write.
select is((select count(*) from public.push_devices), 0::bigint, 'phones and their keys are server-only');
select is((select count(*) from public.activity_tokens), 0::bigint, 'followed sessions are server-only');
select is((select count(*) from public.push_config), 0::bigint, 'the scheduler''s secret is server-only');
select is((select count(*) from public.allowed_signups), 0::bigint, 'the sign-up list is server-only');
select is((select count(*) from public.pairing_failures), 0::bigint, 'the pairing throttle is server-only');
select throws_ok($$insert into public.push_devices (token, user_id, key) values ('a-phone', '00000000-0000-0000-0000-00000000000a', 'k')$$,
  '42501', null, 'phones register only through functions/push');
select throws_ok($$insert into public.allowed_signups (email) values ('me@example.com')$$, '42501', null,
  'nobody signed in can let people in');

-- Pairing codes: only one's own, without the hash, and only revoking.
select is((select count(*) from public.pairing_codes), 0::bigint, 'B''s codes are hidden');
update public.pairing_codes set revoked_at = now() where id = '00000000-0000-0000-0000-0000000003b0';
select throws_ok('select code_hash from public.pairing_codes', '42501', null, 'nobody reads a code''s hash');
select throws_ok($$insert into public.pairing_codes (code_hash, user_id, created_by, expires_at)
  values ('mine', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', now() + interval '1 day')$$,
  '42501', null, 'codes are made only by functions/pair');

-- Storage: one's own folder of each bucket.
select is((select count(*) from storage.objects), 0::bigint, 'B''s images are hidden');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('chat', '00000000-0000-0000-0000-00000000000a/a.png')$$,
  'A uploads into their own folder');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000b/x.png')$$,
  '42501', null, 'but not into B''s');

-- Nothing for anyone signed out.
select pg_temp.sign_out();
select set_config('role', 'anon', true);
select is((select count(*) from public.ideas) + (select count(*) from public.chats), 0::bigint, 'signed out, nothing is visible');
select throws_ok('select id from public.pairing_codes', '42501', null, 'not even which codes exist');
select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'execute'), 'signed out, no account to delete');
select ok(not has_function_privilege('anon', 'public.reviewer_access_active()', 'execute'), 'or access to check');

-- B's rows came through A's attempts untouched.
select pg_temp.sign_out();
select is((select title from public.ideas where id = '00000000-0000-0000-0000-0000000001b0'), 'b', 'B''s idea is unchanged');
select is((select count(*) from public.device_tokens where token_hash = 'b-device'), 1::bigint, 'B''s device token is still there');
select is((select revoked_at from public.pairing_codes where code_hash = 'b-code'), null, 'B''s code still works');

select * from finish();
rollback;
