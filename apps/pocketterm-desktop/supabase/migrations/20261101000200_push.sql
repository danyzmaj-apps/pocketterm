-- Push notifications to the phones (functions/push).
--
-- Each phone registers its push token (an iPhone's APNs device token, an
-- Android phone's FCM registration token) and a key it made itself; this
-- server encrypts every notification with that key and hands only the
-- ciphertext to the push relay (functions/relay, run by the app's publisher,
-- who holds the APNs key and the Firebase service account). The phone
-- decrypts it.
create table public.push_devices (
  token text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- AES-256-GCM, base64; only this server and that phone know it.
  key text not null,
  label text not null default '',
  platform text not null default 'ios' check (platform in ('ios', 'android')),
  updated_at timestamptz not null default now()
);

-- Written by functions/push only (service role); no policies.
alter table public.push_devices enable row level security;

-- Coding sessions followed on the phone. An iPhone's Live Activity has an
-- APNs push token of its own and follows one session, and its pushes carry a
-- state only, no text. An Android phone follows each session with its one FCM
-- token, so there is a row per (token, session); its state travels sealed
-- with the device key.
create table public.activity_tokens (
  token text not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- The session's key (`kitty-<pid>/<window id>`, `pid:<pid>` …).
  session text not null,
  platform text not null default 'ios' check (platform in ('ios', 'android')),
  updated_at timestamptz not null default now(),
  primary key (token, session)
);

create index activity_tokens_user_session on public.activity_tokens (user_id, session);

-- Written by functions/push only (service role); no policies.
alter table public.activity_tokens enable row level security;
