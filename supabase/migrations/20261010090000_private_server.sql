-- A Džep server is private: the first account to sign in owns it, and no one
-- else can sign up unless their email is in allowed_signups. Without this,
-- anyone who learns the project URL could sign in with GitHub and spend the
-- owner's AI key. Enforced by the auth hook below (enabled in config.toml,
-- [auth.hook.before_user_created]; `supabase config push` turns it on for a
-- hosted project).
--
-- Let someone in:   insert into public.allowed_signups (email) values ('friend@example.com');
create table public.allowed_signups (
  email text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);

-- No policies: only the dashboard / SQL editor (postgres) reads or writes it.
alter table public.allowed_signups enable row level security;

create function public.before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from auth.users)
    or exists (select 1 from public.allowed_signups a where a.email = lower(event -> 'user' ->> 'email'))
  then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This Džep server is private. Its owner can let you in by adding your email to allowed_signups.'
  ));
end $$;

revoke execute on function public.before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.before_user_created(jsonb) to supabase_auth_admin;

-- Deletes the signed-in user's account and, by cascade, every idea, todo,
-- chat and device token of theirs. The app empties their Storage folder
-- first (Storage objects aren't tied to the user by a foreign key).
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
