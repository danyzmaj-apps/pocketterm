-- Several computers per account. Each running PocketTerm registers itself
-- here (its id, name and platform) and refreshes seen_at while its bridge
-- runs; the phone lists them and the user picks one.
create table public.desktops (
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  id text not null check (id ~ '^[a-z0-9]{8}$'),
  name text not null check (char_length(name) between 1 and 80),
  platform text not null check (platform in ('macos','windows')),
  seen_at timestamptz not null default now(),
  primary key (user_id, id)
);
alter table public.desktops enable row level security;
create policy "own desktops" on public.desktops for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Each computer has its own terminal topic, `terminal:<user id>:<desktop id>`.
-- Only the user may join theirs, and only with a desktop suffix: the bare
-- `terminal:<user id>` is no one's. A uuid has no characters that need escaping.
drop policy "own terminal topic: receive" on realtime.messages;
drop policy "own terminal topic: send" on realtime.messages;

create policy "own terminal topic: receive" on realtime.messages
  for select to authenticated using (
    realtime.messages.extension = 'broadcast'
    and starts_with((select realtime.topic()), 'terminal:' || (select auth.uid())::text || ':')
  );

create policy "own terminal topic: send" on realtime.messages
  for insert to authenticated with check (
    realtime.messages.extension = 'broadcast'
    and starts_with((select realtime.topic()), 'terminal:' || (select auth.uid())::text || ':')
  );
