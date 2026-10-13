-- Terminal from the iPhone: the Mac's Džep and the iPhone talk over the
-- private Realtime broadcast topic `terminal:<user id>` (nothing is stored).
-- What crosses it can type into the Mac's kitty windows, so only the user may
-- join their own topic, to listen or to send. Clients join with
-- `private: true`; a public channel of the same name is a separate room that
-- the apps never join.
create policy "own terminal topic: receive" on realtime.messages
  for select to authenticated using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'terminal:' || (select auth.uid())::text
  );

create policy "own terminal topic: send" on realtime.messages
  for insert to authenticated with check (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'terminal:' || (select auth.uid())::text
  );
