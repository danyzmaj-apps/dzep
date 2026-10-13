-- Quick-question chats, shared by the Mac and the iPhone. The app picks a
-- chat's id (uuid v4) so a new chat shows before the server knows it; the
-- `ask` edge function is the only writer of messages (it saves the question,
-- streams DeepSeek's answer back and saves that too). Deletes are soft so the
-- other devices learn about them.
create table public.chats (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- The pull cursor, like ideas.
create index chats_user_updated on public.chats (user_id, updated_at);

create trigger chats_touch before insert or update on public.chats
for each row execute function public.ideas_touch();

create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null default '',
  -- Set when the answer failed; such turns are left out of the history sent
  -- to the model.
  error text,
  created_at timestamptz not null default now()
);

create index chat_messages_chat on public.chat_messages (chat_id, created_at);

-- A new message moves its chat's updated_at, so one cursor (and one realtime
-- table) tells every device which chats to refetch.
create function public.chat_messages_bump() returns trigger
language plpgsql as $$
begin
  update public.chats set updated_at = now() where id = new.chat_id;
  return new;
end $$;

create trigger chat_messages_bump after insert on public.chat_messages
for each row execute function public.chat_messages_bump();

alter table public.chats enable row level security;
alter table public.chat_messages enable row level security;

create policy "own chats: read" on public.chats
  for select to authenticated using (user_id = (select auth.uid()));
create policy "own chats: insert" on public.chats
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own chats: update" on public.chats
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "own chat messages: read" on public.chat_messages
  for select to authenticated using (user_id = (select auth.uid()));
-- Only into the user's own chats (the function runs with the user's token).
create policy "own chat messages: insert" on public.chat_messages
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.chats c where c.id = chat_id and c.user_id = (select auth.uid()))
  );

alter publication supabase_realtime add table public.chats;
