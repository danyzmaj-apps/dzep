-- The reviewer demo account and a second account reach none of the owner's
-- rows, images or terminal topic (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000b', 'second@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000d', 'reviewer@x.dzep.invalid', '{"provider": "email", "dzep_demo": true}');

create function pg_temp.sign_in(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', id, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.sign_out() returns void language sql as $$
  select set_config('role', 'none', true), set_config('request.jwt.claims', '', true)
$$;

-- The owner's rows, made by the server; a reviewer code keeps the demo's access open.
insert into public.ideas (id, user_id, title) values ('00000000-0000-0000-0000-0000000001a0', '00000000-0000-0000-0000-00000000000a', 'owner''s');
insert into public.chats (id, user_id) values ('00000000-0000-0000-0000-0000000002a0', '00000000-0000-0000-0000-00000000000a');
insert into public.chat_messages (chat_id, user_id, role, content) values
  ('00000000-0000-0000-0000-0000000002a0', '00000000-0000-0000-0000-00000000000a', 'user', 'owner''s');
insert into public.device_tokens (user_id, token_hash) values ('00000000-0000-0000-0000-00000000000a', 'owner-device');
insert into public.pairing_codes (code_hash, user_id, created_by, reusable, expires_at) values
  ('review', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, now() + interval '30 days');
insert into storage.objects (bucket_id, name) values
  ('chat', '00000000-0000-0000-0000-00000000000a/a.png'), ('terminal', '00000000-0000-0000-0000-00000000000a/t.png');

create function pg_temp.owner_rows() returns bigint language sql security definer as $$
  select (select count(*) from public.ideas where user_id = '00000000-0000-0000-0000-00000000000a' and title = 'owner''s')
       + (select count(*) from public.chats where user_id = '00000000-0000-0000-0000-00000000000a' and deleted_at is null)
       + (select count(*) from public.chat_messages where user_id = '00000000-0000-0000-0000-00000000000a')
       + (select count(*) from public.device_tokens where user_id = '00000000-0000-0000-0000-00000000000a')
       + (select count(*) from storage.objects where name like '00000000-0000-0000-0000-00000000000a/%')
$$;

-- The same attempts as the demo account and as the second account.
create function pg_temp.attempts(who uuid, label text) returns setof text language plpgsql as $fn$
begin
  perform pg_temp.sign_in(who);
  return next is((select count(*) from public.ideas) + (select count(*) from public.chats)
    + (select count(*) from public.chat_messages) + (select count(*) from public.device_tokens), 0::bigint,
    label || ' sees none of the owner''s rows');
  return next is((select count(*) from storage.objects), 0::bigint, label || ' sees none of the owner''s images');
  update public.ideas set title = 'taken' where id = '00000000-0000-0000-0000-0000000001a0';
  update public.chats set deleted_at = now() where id = '00000000-0000-0000-0000-0000000002a0';
  delete from public.device_tokens where token_hash = 'owner-device';
  return next throws_ok($$insert into public.ideas (id, user_id, title) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'x')$$,
    '42501', null, label || ' can''t add a row as the owner');
  return next throws_ok($$insert into public.chat_messages (chat_id, role, content) values ('00000000-0000-0000-0000-0000000002a0', 'user', 'x')$$,
    '42501', null, label || ' can''t write into the owner''s chat');
  return next throws_ok($$insert into storage.objects (bucket_id, name) values ('chat', '00000000-0000-0000-0000-00000000000a/x.png')$$,
    '42501', null, label || ' can''t upload into the owner''s folder');
  -- Terminal from the phone: the owner's private topic, to listen or to send.
  perform set_config('realtime.topic', 'terminal:00000000-0000-0000-0000-00000000000a', true);
  return next is((select count(*) from realtime.messages), 0::bigint, label || ' hears nothing on the owner''s terminal topic');
  return next throws_ok($$insert into realtime.messages (topic, extension, payload, event, private)
    values ('terminal:00000000-0000-0000-0000-00000000000a', 'broadcast', '{}', 'type', true)$$,
    '42501', null, label || ' can''t send on the owner''s terminal topic');
  perform set_config('realtime.topic', 'terminal:' || who::text, true);
  return next lives_ok(format($$insert into realtime.messages (topic, extension, payload, event, private)
    values ('terminal:%s', 'broadcast', '{}', 'type', true)$$, who),
    label || ' can send on its own terminal topic');
  perform pg_temp.sign_out();
  return next is(pg_temp.owner_rows(), 6::bigint, label || ' changed none of the owner''s rows or images');
end $fn$;

select * from pg_temp.attempts('00000000-0000-0000-0000-00000000000d', 'the demo account');
select * from pg_temp.attempts('00000000-0000-0000-0000-00000000000b', 'a second account');

-- Signed out: nothing of anyone's, and no terminal topic.
select set_config('role', 'anon', true);
select is((select count(*) from public.ideas) + (select count(*) from storage.objects), 0::bigint, 'signed out sees nothing');
select set_config('realtime.topic', 'terminal:00000000-0000-0000-0000-00000000000a', true);
select throws_ok($$insert into realtime.messages (topic, extension, payload, event, private)
  values ('terminal:00000000-0000-0000-0000-00000000000a', 'broadcast', '{}', 'type', true)$$,
  '42501', null, 'signed out can''t send on any terminal topic');
select pg_temp.sign_out();
select is(pg_temp.owner_rows(), 6::bigint, 'the owner''s rows and images are all still there');

select * from finish();
rollback;
