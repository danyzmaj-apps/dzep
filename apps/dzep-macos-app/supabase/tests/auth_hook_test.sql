-- public.before_user_created: who may sign up on a private server (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

create function pg_temp.signup(email text, app_metadata jsonb) returns jsonb language sql as $$
  select public.before_user_created(jsonb_build_object('user', jsonb_build_object('email', email, 'app_metadata', app_metadata)))
$$;

-- An empty server: the first GitHub account owns it, but never through email.
select is(pg_temp.signup('owner@example.com', '{"provider": "github"}'), '{}'::jsonb,
  'the first GitHub sign-in is let in');
select is(pg_temp.signup('owner@example.com', '{"provider": "email"}') -> 'error' ->> 'http_code', '403',
  'an email sign-up is refused even on an empty server');
select is(pg_temp.signup('owner@example.com', '{"provider": "phone"}') -> 'error' ->> 'http_code', '403',
  'so is a phone sign-up');
select is(pg_temp.signup('anon@example.com', '{}') -> 'error' ->> 'http_code', '403',
  'and one that names no provider (anonymous)');

-- The demo account (functions/pair, service role) neither counts as the owner nor needs to be allowed.
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000d', 'reviewer@x.dzep.invalid', '{"provider": "email", "dzep_demo": true}');
select is(pg_temp.signup('owner@example.com', '{"provider": "github"}'), '{}'::jsonb,
  'with only the demo account, the owner can still sign up');
select is(pg_temp.signup('reviewer@y.dzep.invalid', '{"provider": "email", "dzep_demo": true}'), '{}'::jsonb,
  'the demo account is let in');

-- Once there is an owner, only allowed emails, and still only through GitHub.
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"provider": "github"}');
select is(pg_temp.signup('stranger@example.com', '{"provider": "github"}') -> 'error' ->> 'http_code', '403',
  'a stranger is refused');
select matches(pg_temp.signup('stranger@example.com', '{"provider": "github"}') -> 'error' ->> 'message', 'allowed_signups',
  'and told how the owner can let them in');

insert into public.allowed_signups (email) values ('friend@example.com');
select is(pg_temp.signup('Friend@Example.com', '{"provider": "github"}'), '{}'::jsonb,
  'an allowed email is let in, whatever its case');
select is(pg_temp.signup('friend@example.com', '{"provider": "email"}') -> 'error' ->> 'http_code', '403',
  'but not by signing up with that address and a password');

select ok(not has_function_privilege('authenticated', 'public.before_user_created(jsonb)', 'execute'),
  'only the auth server runs the hook');

select * from finish();
rollback;
