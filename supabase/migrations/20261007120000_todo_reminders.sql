-- A todo can carry a reminder: each device schedules a local notification
-- for remind_at (lib/remind.dart). Null is no reminder. Clients that predate
-- the column never send it, so their upserts leave it as it is.
alter table public.ideas add column remind_at timestamptz;
