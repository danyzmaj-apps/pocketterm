-- A PocketTerm server: who may sign up, phones signing in with a code from the
-- computer, the reviewer demo account and deleting one's account.

-- A PocketTerm server is private: the first account to sign in owns it, and no
-- one else can sign up unless their email is in allowed_signups. Enforced by
-- the auth hook below (enabled in config.toml, [auth.hook.before_user_created];
-- `supabase config push` turns it on for a hosted project).
--
-- Let someone in:   insert into public.allowed_signups (email) values ('friend@example.com');
create table public.allowed_signups (
  email text primary key check (email = lower(email)),
  created_at timestamptz not null default now()
);

-- No policies: only the dashboard / SQL editor (postgres) reads or writes it.
alter table public.allowed_signups enable row level security;

-- Phones sign in only with a code from the computer (functions/pair), never
-- with GitHub. A code is a random string the computer shows in a QR (inside a
-- setup link); only its SHA-256 is kept here. Redeeming it makes a fresh
-- magic-link token for the code's user, which the phone turns into its own
-- session.
--
-- Two kinds:
--   * a phone's code (Settings → Set up phone…): single use, 10 minutes, for
--     the signed-in user;
--   * a reviewer code (Settings → Reviewer access): reusable until it expires
--     or is revoked, for a separate demo account on this server, so App Store
--     and Play reviewers can sign in without the owner's computer. The demo
--     account is made by the function with app_metadata.pocketterm_demo = true;
--     it has no access to the owner's rows (every table is own-rows only).
create table public.pairing_codes (
  id uuid primary key default gen_random_uuid(),
  -- Who the code signs in.
  user_id uuid not null references auth.users (id) on delete cascade,
  -- Who made it (the owner, also for a reviewer code): the one who lists and
  -- revokes it.
  created_by uuid not null references auth.users (id) on delete cascade,
  code_hash text not null unique,
  reusable boolean not null default false,
  label text not null default '',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

create index pairing_codes_created_by on public.pairing_codes (created_by);
create index pairing_codes_user_id on public.pairing_codes (user_id);

alter table public.pairing_codes enable row level security;

-- Clients see their own codes without the hashes, and can only revoke them;
-- codes are made and redeemed by functions/pair (service role).
revoke all on public.pairing_codes from anon, authenticated;
grant select (id, user_id, created_by, reusable, label, expires_at, created_at, last_used_at, revoked_at)
  on public.pairing_codes to authenticated;
grant update (revoked_at) on public.pairing_codes to authenticated;

create policy "own codes: read" on public.pairing_codes
  for select to authenticated using (created_by = (select auth.uid()));
create policy "own codes: revoke" on public.pairing_codes
  for update to authenticated using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));

-- Failed redeems per caller, for a cheap throttle. The codes carry 140 random
-- bits, so guessing is hopeless anyway; this only keeps a flood cheap.
create table public.pairing_failures (
  ip text not null,
  at timestamptz not null default now()
);

create index pairing_failures_ip_at on public.pairing_failures (ip, at);

-- No policies: only the service role.
alter table public.pairing_failures enable row level security;

-- Who may sign up. Only through a provider that proves who you are (GitHub):
-- email sign-up is off in config.toml, but a project set up some other way
-- may still allow it, and then anyone could claim an allowed (or, before the
-- owner's first sign-in, any) address without owning it. The demo account,
-- made by functions/pair with the service role, is the one email account;
-- only the service role can set app_metadata, so a stranger's sign-up can't
-- claim to be it. The demo account doesn't count as "the first account": an
-- owner who deleted theirs can still sign in again.
create function public.before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if event -> 'user' -> 'app_metadata' ->> 'pocketterm_demo' = 'true' then
    return '{}'::jsonb;
  end if;
  if coalesce(event -> 'user' -> 'app_metadata' ->> 'provider', 'email') in ('email', 'phone', 'anonymous') then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'This PocketTerm server signs in with GitHub only.'
    ));
  end if;
  if not exists (
      select 1 from auth.users u where coalesce(u.raw_app_meta_data ->> 'pocketterm_demo', '') <> 'true'
    )
    or exists (select 1 from public.allowed_signups a where a.email = lower(event -> 'user' ->> 'email'))
  then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This PocketTerm server is private. Its owner can let you in by adding your email to allowed_signups.'
  ));
end $$;

revoke execute on function public.before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.before_user_created(jsonb) to supabase_auth_admin;

-- Uses a code, all in one statement so two phones racing on a single-use
-- code can't both win: {"user_id"} when it works, {"error": "invalid"} for a
-- code that doesn't exist, expired, was revoked or (single use) was used,
-- {"error": "throttled"} after 10 failures from the same caller in 10 minutes.
-- Failures count only when the platform names the caller (functions/pair
-- passes null otherwise): one shared bucket for every unknown caller would
-- let ten bad tries lock out every phone.
create function public.redeem_pairing_code(p_hash text, p_ip text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid;
begin
  if p_ip is not null and (select count(*) from public.pairing_failures f
      where f.ip = p_ip and f.at > now() - interval '10 minutes') >= 10 then
    return '{"error": "throttled"}'::jsonb;
  end if;
  update public.pairing_codes c set last_used_at = now()
    where c.code_hash = p_hash
      and c.revoked_at is null
      and c.expires_at > now()
      and (c.reusable or c.last_used_at is null)
    returning c.user_id into uid;
  if uid is null then
    if p_ip is not null then
      delete from public.pairing_failures f where f.at < now() - interval '1 hour';
      insert into public.pairing_failures (ip) values (p_ip);
    end if;
    return '{"error": "invalid"}'::jsonb;
  end if;
  return jsonb_build_object('user_id', uid);
end $$;

revoke execute on function public.redeem_pairing_code(text, text) from public, anon, authenticated;
grant execute on function public.redeem_pairing_code(text, text) to service_role;

-- The server's demo account (for reviewer codes), if it has one.
create function public.pairing_demo_user() returns uuid
language sql stable security definer set search_path = '' as $$
  select u.id from auth.users u
  where u.raw_app_meta_data ->> 'pocketterm_demo' = 'true'
  order by u.created_at
  limit 1
$$;

revoke execute on function public.pairing_demo_user() from public, anon, authenticated;
grant execute on function public.pairing_demo_user() to service_role;

-- Whether the signed-in user may still use the server: always, except the
-- demo account once none of its reviewer codes works (revoked, run out, or
-- the owner's account deleted). functions/pair checks it.
create function public.reviewer_access_active() returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
      select 1 from auth.users u where u.id = (select auth.uid()) and u.raw_app_meta_data ->> 'pocketterm_demo' = 'true'
    )
    or exists (
      select 1 from public.pairing_codes c
      where c.user_id = (select auth.uid()) and c.reusable and c.revoked_at is null and c.expires_at > now()
    )
$$;

revoke execute on function public.reviewer_access_active() from public, anon;
grant execute on function public.reviewer_access_active() to authenticated;

-- Signs the demo account out everywhere once no reviewer code of it works:
-- a session made from a code (a magic link, then rotating refresh tokens)
-- would otherwise outlive the code. An access token already out stays a
-- valid JWT for PostgREST until it expires; the phone notices the session is
-- gone (Session.checkReviewerAccess) and signs out. Returns how many sessions ended.
create function public.end_idle_demo_sessions() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  ended integer;
begin
  with idle as (
    select u.id from auth.users u
    where u.raw_app_meta_data ->> 'pocketterm_demo' = 'true'
      and not exists (
        select 1 from public.pairing_codes c
        where c.user_id = u.id and c.reusable and c.revoked_at is null and c.expires_at > now()
      )
  ),
  gone as (
    delete from auth.sessions s using idle where s.user_id = idle.id returning 1
  )
  select count(*) into ended from gone;
  return ended;
end $$;

revoke execute on function public.end_idle_demo_sessions() from public, anon, authenticated;

-- Right away when a code is revoked or deleted (the owner deleting their
-- account deletes their codes) ...
create function public.pairing_codes_end_idle_demo_sessions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.end_idle_demo_sessions();
  return null;
end $$;

revoke execute on function public.pairing_codes_end_idle_demo_sessions() from public, anon, authenticated;

create trigger end_idle_demo_sessions
  after update of revoked_at or delete on public.pairing_codes
  for each statement execute function public.pairing_codes_end_idle_demo_sessions();

-- ... and within 10 minutes of the last one running out.
create extension if not exists pg_cron;
select cron.schedule('pocketterm-demo-sessions', '*/10 * * * *', 'select public.end_idle_demo_sessions()');

-- Deletes the signed-in user's account and, by cascade, every row of theirs.
-- The app empties their Storage folder first (Storage objects aren't tied to
-- the user by a foreign key).
--
-- The demo account deleting "itself" (App and Play reviewers try in-app
-- account deletion) empties it instead: its rows go, the account stays.
-- Deleting it would cascade to every reviewer code, including the ones
-- already handed to App Store Connect and Play, and lock out the next review.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from auth.users u where u.id = uid and u.raw_app_meta_data ->> 'pocketterm_demo' = 'true') then
    delete from public.push_devices where user_id = uid;
    delete from public.activity_tokens where user_id = uid;
    -- Phone codes it made for itself; reviewer codes are the owner's.
    delete from public.pairing_codes where user_id = uid and not reusable;
    return;
  end if;
  delete from auth.users where id = uid;
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
