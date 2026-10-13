-- Android phones (functions/push, docs/ARCHITECTURE.md). They push through
-- Firebase Cloud Messaging instead of APNs: their token is the FCM
-- registration token, and every message, a followed omp session's state
-- included, is sealed with the key the phone registered. Rows from before
-- this are iPhones.

alter table public.push_devices
  add column platform text not null default 'ios' check (platform in ('ios', 'android'));

alter table public.activity_tokens
  add column platform text not null default 'ios' check (platform in ('ios', 'android'));

-- An iPhone's Live Activity has a token of its own, but an Android phone
-- follows each omp session with its one FCM token: a row per (token, session).
-- Tokens are unique so far, so the pairs are too.
alter table public.activity_tokens drop constraint activity_tokens_pkey;
alter table public.activity_tokens add primary key (token, session);
