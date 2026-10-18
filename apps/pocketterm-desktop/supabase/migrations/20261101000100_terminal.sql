-- Terminal from the phone: the computer's PocketTerm and the phone talk over
-- the private Realtime broadcast topic `terminal:<user id>` (nothing is
-- stored). What crosses it can type into the computer's terminal windows, so
-- only the user may join their own topic, to listen or to send. Clients join
-- with `private: true`; a public channel of the same name is a separate room
-- that the apps never join.
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

-- Images the phone sends into a coding session. The phone uploads one to
-- `terminal/<user id>/<uuid>`, the computer's PocketTerm downloads it, puts it
-- on the clipboard for the agent and deletes it. Private; each user reaches
-- only their own folder.
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
