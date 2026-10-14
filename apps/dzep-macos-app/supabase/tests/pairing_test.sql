-- public.redeem_pairing_code: what functions/pair relies on (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000d', 'reviewer@x.dzep.invalid', '{"provider": "email", "dzep_demo": true}');

insert into public.pairing_codes (code_hash, user_id, created_by, reusable, expires_at, revoked_at) values
  ('phone', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', false, now() + interval '10 minutes', null),
  ('reviewer', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, now() + interval '30 days', null),
  ('expired', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', false, now() - interval '1 second', null),
  ('revoked', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, now() + interval '30 days', now());

-- A phone's code works once.
select is(public.redeem_pairing_code('phone', '192.0.2.1'), '{"user_id": "00000000-0000-0000-0000-00000000000a"}'::jsonb,
  'a phone code signs in its user');
select is(public.redeem_pairing_code('phone', '192.0.2.1'), '{"error": "invalid"}'::jsonb, 'a used phone code is spent');

-- A reviewer code works again and again, for the demo account.
select is(public.redeem_pairing_code('reviewer', '192.0.2.1'), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'a reviewer code signs in the demo account');
select is(public.redeem_pairing_code('reviewer', '192.0.2.1'), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'a reviewer code is reusable');
select isnt((select last_used_at from public.pairing_codes where code_hash = 'reviewer'), null, 'redeeming notes when');

select is(public.redeem_pairing_code('expired', '192.0.2.1'), '{"error": "invalid"}'::jsonb, 'a run-out code fails');
select is(public.redeem_pairing_code('revoked', '192.0.2.1'), '{"error": "invalid"}'::jsonb, 'a revoked code fails');
select is(public.redeem_pairing_code('nope', '192.0.2.1'), '{"error": "invalid"}'::jsonb, 'an unknown code fails');

-- Failures are counted per caller: 10 in 10 minutes and that caller waits.
do $$ begin perform public.redeem_pairing_code('nope', '192.0.2.2') from generate_series(1, 9); end $$;
select is(public.redeem_pairing_code('nope', '192.0.2.2'), '{"error": "invalid"}'::jsonb, 'the tenth failure still reads invalid');
select is(public.redeem_pairing_code('reviewer', '192.0.2.2'), '{"error": "throttled"}'::jsonb,
  'after 10 failures even a good code waits');
select is(public.redeem_pairing_code('reviewer', '192.0.2.3'), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'another caller is not throttled');

-- Old failures don't count.
update public.pairing_failures set at = now() - interval '11 minutes' where ip = '192.0.2.2';
select is(public.redeem_pairing_code('reviewer', '192.0.2.2'), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'the throttle lifts after 10 minutes');

-- An unknown caller (no address the platform vouches for) is never throttled
-- and leaves nothing behind: one shared bucket would lock everyone out.
do $$ begin perform public.redeem_pairing_code('nope', null) from generate_series(1, 12); end $$;
select is(public.redeem_pairing_code('reviewer', null), '{"user_id": "00000000-0000-0000-0000-00000000000d"}'::jsonb,
  'failures without a caller address throttle nobody');
select is((select count(*) from public.pairing_failures where ip is null), 0::bigint, 'and are not recorded');

-- Only the service role (functions/pair) may redeem.
select ok(not has_function_privilege('anon', 'public.redeem_pairing_code(text, text)', 'execute'), 'anon cannot redeem');
select ok(not has_function_privilege('authenticated', 'public.redeem_pairing_code(text, text)', 'execute'),
  'a signed-in user cannot redeem');

select * from finish();
rollback;
