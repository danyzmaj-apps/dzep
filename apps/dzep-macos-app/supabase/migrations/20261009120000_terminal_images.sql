-- Terminal from iPhone: images the phone sends into an omp session. The
-- phone uploads one to `terminal/<user id>/<uuid>`, the Mac's Džep downloads
-- it, puts it on the clipboard for omp and deletes it. Private; each user
-- reaches only their own folder.
insert into storage.buckets (id, name, public, file_size_limit)
values ('terminal', 'terminal', false, 20971520);

create policy "own terminal images: upload" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'terminal' and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own terminal images: read" on storage.objects
  for select to authenticated using (
    bucket_id = 'terminal' and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "own terminal images: delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'terminal' and (storage.foldername(name))[1] = (select auth.uid())::text
  );
