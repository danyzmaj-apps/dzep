-- Images in quick questions: the app uploads each to the private `chat`
-- bucket as `<user id>/<uuid>.<ext>` (downscaled to 2048 px at most), and
-- the question's row lists those paths. The `ask` function reads them with
-- the user's token and sends them to the model with the question.
alter table public.chat_messages add column images text[] not null default '{}';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', false, 10485760, array['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

create policy "own chat images: upload" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'chat' and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own chat images: read" on storage.objects
  for select to authenticated using (
    bucket_id = 'chat' and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own chat images: delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'chat' and (storage.foldername(name))[1] = (select auth.uid())::text
  );
