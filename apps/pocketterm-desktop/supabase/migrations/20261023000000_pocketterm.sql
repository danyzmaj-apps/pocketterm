-- PocketTerm on Supabase: the same server as packages/pocketterm_server (PROTOCOL.md), for one owner, in one
-- project. The Edge Function `pocketterm` (functions/pocketterm/index.ts) answers the REST paths and calls the
-- pocketterm_* functions below with the service key; nothing else can reach this data. Devices hold random
-- tokens of which only the SHA-256 is kept here. The live channel is Realtime broadcast on private topics (a
-- computer's id), allowed for a device the function minted a short-lived token for (pocketterm.live_ok).
-- Images and files sit sealed in the private Storage bucket pocketterm-blobs.

create schema if not exists pocketterm;
revoke all on schema pocketterm from public;

-- The one server: its id (GET /v1/me) and the SHA-256 of its setup token, set by the setup on a computer
-- (pocketterm.set_setup_hash) and replaced by POST /v1/setup/new. tick_url and tick_secret let pg_cron call
-- the function every minute (pocketterm.tick).
create table pocketterm.server (
  one boolean primary key default true check (one),
  id text not null default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  setup_hash text,
  tick_url text,
  tick_secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into pocketterm.server default values;

create table pocketterm.devices (
  id text primary key check (id ~ '^[a-z0-9]{16}$'),
  token_hash text not null unique,
  role text not null check (role in ('desktop', 'phone')),
  label text not null default '' check (char_length(label) <= 80),
  platform text not null check (platform in ('macos', 'windows', 'linux', 'ios', 'android')),
  created_at timestamptz not null default now(),
  seen_at timestamptz not null default now()
);

create table pocketterm.desktops (
  id text primary key check (id ~ '^[a-z0-9]{8}$'),
  name text not null check (char_length(name) <= 80),
  platform text not null check (platform in ('macos', 'windows', 'linux')),
  seen_at timestamptz not null default now(),
  -- The computer that put it last; it leaves with that computer.
  device text references pocketterm.devices (id) on delete cascade
);

create table pocketterm.pairing_codes (
  hash text primary key,
  expires timestamptz not null,
  made_by text not null references pocketterm.devices (id) on delete cascade
);

create table pocketterm.push_tokens (
  token text primary key,
  platform text not null check (platform in ('ios', 'android')),
  label text not null default '',
  device text not null references pocketterm.devices (id) on delete cascade
);

create table pocketterm.activity_tokens (
  token text not null,
  session text not null,
  platform text not null check (platform in ('ios', 'android')),
  device text not null references pocketterm.devices (id) on delete cascade,
  ref text,
  primary key (token, session)
);
create index on pocketterm.activity_tokens (session);

create table pocketterm.redeem_failures (
  caller text not null,
  at timestamptz not null default now()
);

-- Each blob in the bucket: who uploaded it, its size (the caps: 200 MiB per device, 1 GiB in all) and when (it
-- goes after an hour). The bytes are in Storage under the same path.
create table pocketterm.blobs (
  path text primary key check (path ~ '^[A-Za-z0-9-]{1,64}$'),
  device text references pocketterm.devices (id) on delete set null,
  size bigint not null,
  created_at timestamptz not null default now()
);
create index on pocketterm.redeem_failures (caller, at);

alter table pocketterm.server enable row level security;
alter table pocketterm.devices enable row level security;
alter table pocketterm.desktops enable row level security;
alter table pocketterm.pairing_codes enable row level security;
alter table pocketterm.push_tokens enable row level security;
alter table pocketterm.activity_tokens enable row level security;
alter table pocketterm.redeem_failures enable row level security;
alter table pocketterm.blobs enable row level security;

-- Images and files, sealed by the apps; at most 20 MiB each.
insert into storage.buckets (id, name, public, file_size_limit)
values ('pocketterm-blobs', 'pocketterm-blobs', false, 20971520)
on conflict (id) do nothing;

-- Answers ------------------------------------------------------------------------------------------------------

-- What the function answers with instead: {fail: {status, error, message, retry_after?}}.
create function pocketterm.fail(p_status int, p_error text, p_message text, p_retry int default null)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('fail', jsonb_strip_nulls(jsonb_build_object(
    'status', p_status, 'error', p_error, 'message', p_message, 'retry_after', p_retry)));
$$;

create function pocketterm.iso(t timestamptz) returns text language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

create function pocketterm.device_json(d pocketterm.devices) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', d.id, 'role', d.role, 'label', d.label, 'platform', d.platform,
    'created_at', pocketterm.iso(d.created_at), 'seen_at', pocketterm.iso(d.seen_at));
$$;

create function pocketterm.desktop_json(d pocketterm.desktops) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', d.id, 'name', d.name, 'platform', d.platform,
    'seen_at', pocketterm.iso(d.seen_at), 'online', d.seen_at > now() - interval '150 seconds');
$$;

-- The device holding the token whose SHA-256 is p_hash, its seen_at stamped (kept to the minute); null when
-- there is none.
create function pocketterm.auth(p_hash text) returns pocketterm.devices
language plpgsql set search_path = '' as $$
declare
  me pocketterm.devices;
begin
  update pocketterm.devices set seen_at = now()
    where token_hash = p_hash and seen_at < now() - interval '1 minute'
    returning * into me;
  if me.id is null then
    select * into me from pocketterm.devices where token_hash = p_hash;
  end if;
  return me;
end;
$$;

create function pocketterm.unauthorized() returns jsonb language sql immutable set search_path = '' as $$
  select pocketterm.fail(401, 'unauthorized', 'Sign in again: this device is not signed in to the server.');
$$;

create function pocketterm.desktop_only() returns jsonb language sql immutable set search_path = '' as $$
  select pocketterm.fail(403, 'forbidden', 'Only a computer can do this.');
$$;

-- Whether computer p_desktop is held by another computer than p_device: one that put it, is still signed in
-- (else the row is gone with it) and keeps it online. A row gone quiet may be taken over: a computer that lost
-- its token but kept its id goes on working.
create function pocketterm.held_by_other(p_desktop text, p_device text) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from pocketterm.desktops d where d.id = p_desktop and d.device is not null
    and d.device <> p_device and d.seen_at > now() - interval '150 seconds');
$$;

-- Activity tokens as the function turns them into pushes.
create function pocketterm.tokens_json(rows pocketterm.activity_tokens[]) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('token', t.token, 'session', t.session, 'platform', t.platform,
    'ref', t.ref)), '[]'::jsonb) from unnest(rows) t;
$$;

-- Tells every device on a computer's topic to check its sign-in (GET /v1/me): one was signed out. The
-- message holds nothing; a device still signed in carries on.
create function pocketterm.tell_left() returns void language plpgsql set search_path = '' as $$
declare
  d record;
begin
  for d in select id from pocketterm.desktops loop
    begin
      perform realtime.send('{}'::jsonb, 'pt.left', d.id, true);
    exception when others then
      -- Realtime not there yet: nobody is listening either.
      null;
    end;
  end loop;
end;
$$;

-- Ends (deletes) the activity tokens following a session of computer p_desktop; the deleted rows.
create function pocketterm.end_desktop(p_desktop text) returns pocketterm.activity_tokens[]
language plpgsql set search_path = '' as $$
declare
  gone pocketterm.activity_tokens[];
begin
  select coalesce(array_agg(t), '{}') into gone from pocketterm.activity_tokens t
    where split_part(t.session, '/', 1) = p_desktop;
  delete from pocketterm.activity_tokens where split_part(session, '/', 1) = p_desktop;
  return gone;
end;
$$;

-- Setup and pairing ----------------------------------------------------------------------------------------

-- The setup on a computer sets the first setup token (only its hash comes here).
create function pocketterm.set_setup_hash(p_hash text) returns void language sql set search_path = '' as $$
  update pocketterm.server set setup_hash = p_hash where one;
$$;

-- Throttle for both redeems: 10 failures from one caller within 10 minutes and it waits.
create function pocketterm.throttled(p_caller text) returns jsonb language plpgsql set search_path = '' as $$
declare
  n int;
  oldest timestamptz;
begin
  delete from pocketterm.redeem_failures where at < now() - interval '10 minutes';
  select count(*), min(at) into n, oldest from pocketterm.redeem_failures where caller = p_caller;
  if n >= 10 then
    return pocketterm.fail(429, 'rate_limited',
      format('Too many tries from this network. Wait %s minute%s, then try again.',
        ceil(extract(epoch from (oldest + interval '10 minutes' - now())) / 60)::int,
        case when ceil(extract(epoch from (oldest + interval '10 minutes' - now())) / 60)::int = 1 then '' else 's' end),
      ceil(extract(epoch from (oldest + interval '10 minutes' - now())))::int + 1);
  end if;
  return null;
end;
$$;

create function pocketterm.new_device(p_id text, p_token_hash text, p_role text, p_label text, p_platform text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  d pocketterm.devices;
begin
  insert into pocketterm.devices (id, token_hash, role, label, platform)
    values (p_id, p_token_hash, p_role, p_label, p_platform) returning * into d;
  return jsonb_build_object('device', pocketterm.device_json(d));
end;
$$;

-- POST /v1/setup/redeem. p_caller: the throttle's key for the caller; a failure (any 400) counts.
create function public.pocketterm_setup_redeem(p_caller text, p_setup_hash text, p_id text, p_token_hash text,
  p_label text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wait jsonb := pocketterm.throttled(p_caller);
begin
  if wait is not null then return wait; end if;
  if p_platform is null or p_setup_hash is null
     or p_setup_hash is distinct from (select setup_hash from pocketterm.server) then
    insert into pocketterm.redeem_failures (caller) values (p_caller);
    if p_platform is null then
      return pocketterm.fail(400, 'bad_request', 'platform must be macos, windows, linux.');
    end if;
    return pocketterm.fail(400, 'invalid_code',
      'That setup link doesn''t work: it was replaced by a newer one. Get the current one in PocketTerm on a '
      'computer of yours that is signed in (Settings, Account, Add a computer).');
  end if;
  return pocketterm.new_device(p_id, p_token_hash, 'desktop', p_label, p_platform);
end;
$$;

-- POST /v1/setup/new: a new setup token (its hash); the old one stops working, nobody is signed out.
create function public.pocketterm_setup_new(p_token text, p_setup_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  update pocketterm.server set setup_hash = p_setup_hash where one;
  return jsonb_build_object('ok', true);
end;
$$;

-- POST /v1/pair: keeps a pairing code's hash for 10 minutes.
create function public.pocketterm_pair(p_token text, p_code_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  until timestamptz := now() + interval '10 minutes';
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  insert into pocketterm.pairing_codes (hash, expires, made_by) values (p_code_hash, until, me.id);
  return jsonb_build_object('expires', pocketterm.iso(until));
end;
$$;

-- POST /v1/pair/redeem: uses the code up.
create function public.pocketterm_pair_redeem(p_caller text, p_code_hash text, p_id text, p_token_hash text,
  p_label text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  wait jsonb := pocketterm.throttled(p_caller);
  found pocketterm.pairing_codes;
begin
  if wait is not null then return wait; end if;
  if p_platform is null then
    insert into pocketterm.redeem_failures (caller) values (p_caller);
    return pocketterm.fail(400, 'bad_request', 'platform must be ios, android.');
  end if;
  delete from pocketterm.pairing_codes where hash = p_code_hash returning * into found;
  if found.hash is null or found.expires <= now() then
    insert into pocketterm.redeem_failures (caller) values (p_caller);
    return pocketterm.fail(400, 'invalid_code',
      'That code doesn''t work: it may have run out or been used already. Make a new one in PocketTerm on '
      'your computer (Settings, Add a phone).');
  end if;
  return pocketterm.new_device(p_id, p_token_hash, 'phone', p_label, p_platform);
end;
$$;

-- Devices and desktops -------------------------------------------------------------------------------------

-- GET /v1/me
create function public.pocketterm_me(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  return jsonb_build_object('device', pocketterm.device_json(me),
    'server', jsonb_build_object('id', (select id from pocketterm.server)));
end;
$$;

-- GET /v1/devices
create function public.pocketterm_devices(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  return (select coalesce(jsonb_agg(pocketterm.device_json(d) || jsonb_build_object('current', d.id = me.id)
    order by d.created_at, d.id), '[]'::jsonb) from pocketterm.devices d);
end;
$$;

-- DELETE /v1/devices/:id ('me' leaves). The device goes with its push and activity tokens and the desktops it
-- put; returns the Live Activities to end (its own, and those following its desktops' sessions).
create function public.pocketterm_drop_device(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  target text;
  ending pocketterm.activity_tokens[] := '{}';
  d record;
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  target := case when p_id = 'me' then me.id else p_id end;
  if target <> me.id and me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  if not exists (select 1 from pocketterm.devices where id = target) then
    return pocketterm.fail(404, 'not_found', 'No such device.');
  end if;
  perform pocketterm.tell_left();
  select coalesce(array_agg(t), '{}') into ending from pocketterm.activity_tokens t where t.device = target;
  for d in select id from pocketterm.desktops where device = target loop
    ending := ending || pocketterm.end_desktop(d.id);
  end loop;
  delete from pocketterm.devices where id = target;
  return jsonb_build_object('ok', true, 'end', pocketterm.tokens_json(ending));
end;
$$;

-- POST /v1/erase: every device, desktop, code and token; returns the Live Activities to end and the blobs to
-- delete. The setup token and the server id stay.
create function public.pocketterm_erase(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  ending pocketterm.activity_tokens[];
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  perform pocketterm.tell_left();
  select coalesce(array_agg(t), '{}') into ending from pocketterm.activity_tokens t;
  -- Every row (pg_safeupdate, which PostgREST's calls run under, wants a where).
  delete from pocketterm.activity_tokens where true;
  delete from pocketterm.push_tokens where true;
  delete from pocketterm.pairing_codes where true;
  delete from pocketterm.desktops where true;
  delete from pocketterm.devices where true;
  delete from pocketterm.blobs where true;
  return jsonb_build_object('ok', true, 'end', pocketterm.tokens_json(ending),
    'blobs', (select coalesce(jsonb_agg(name), '[]'::jsonb) from storage.objects where bucket_id = 'pocketterm-blobs'));
end;
$$;

-- GET /v1/desktops
create function public.pocketterm_desktops(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  return (select coalesce(jsonb_agg(pocketterm.desktop_json(d) order by d.seen_at desc), '[]'::jsonb)
    from pocketterm.desktops d);
end;
$$;

-- PUT /v1/desktops/:id: not one another computer holds (pocketterm.held_by_other).
create function public.pocketterm_put_desktop(p_token text, p_id text, p_name text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  d pocketterm.desktops;
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  if pocketterm.held_by_other(p_id, me.id) then
    return pocketterm.fail(403, 'forbidden', 'Only the computer that added it can change it.');
  end if;
  insert into pocketterm.desktops (id, name, platform, seen_at, device) values (p_id, p_name, p_platform, now(), me.id)
    on conflict (id) do update set name = excluded.name, platform = excluded.platform, seen_at = now(),
      device = excluded.device
    returning * into d;
  return pocketterm.desktop_json(d);
end;
$$;

-- DELETE /v1/desktops/:id: not one another computer holds; returns the Live Activities to end.
create function public.pocketterm_delete_desktop(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
  if pocketterm.held_by_other(p_id, me.id) then
    return pocketterm.fail(403, 'forbidden', 'Only the computer that added it can remove it.');
  end if;
  delete from pocketterm.desktops where id = p_id;
  return jsonb_build_object('ok', true, 'end', pocketterm.tokens_json(pocketterm.end_desktop(p_id)));
end;
$$;

-- PUT /v1/blobs/:path, before the upload: keeps its place, within the caps. 409 when the path is taken, 429
-- when this device holds 200 MiB already (until its oldest goes), 507 when the project holds 1 GiB.
create function public.pocketterm_blob_reserve(p_token text, p_path text, p_size bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  mine bigint;
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  -- An hour old is gone: the sweep may not have come by yet.
  delete from pocketterm.blobs where created_at < now() - interval '1 hour';
  if exists (select 1 from pocketterm.blobs where path = p_path) then
    return pocketterm.fail(409, 'conflict', 'That blob path is taken.');
  end if;
  select coalesce(sum(size), 0) into mine from pocketterm.blobs where device = me.id;
  if mine + p_size > 200 * 1048576 then
    return pocketterm.fail(429, 'rate_limited',
      'This device has too many uploads waiting on the server. Try again once your computer has picked them up.',
      60);
  end if;
  if (select coalesce(sum(size), 0) from pocketterm.blobs) + p_size > 1024 * 1048576 then
    return pocketterm.fail(507, 'storage_full', 'The server has no room for more uploads right now. Try again in a while.');
  end if;
  insert into pocketterm.blobs (path, device, size) values (p_path, me.id, p_size) on conflict (path) do nothing;
  if not found then return pocketterm.fail(409, 'conflict', 'That blob path is taken.'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- A blob downloaded, deleted, or whose upload failed: its place goes.
create function public.pocketterm_blob_gone(p_path text)
returns void language sql security definer set search_path = '' as $$
  delete from pocketterm.blobs where path = p_path;
$$;

-- GET /v1/blobs/:path: whether it is there and under an hour old.
create function public.pocketterm_blob_fresh(p_token text, p_path text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  return to_jsonb(exists (select 1 from pocketterm.blobs
    where path = p_path and created_at >= now() - interval '1 hour'));
end;
$$;

-- Any authenticated call that needs only who's asking (blobs, the live channel's token).
create function public.pocketterm_whoami(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  return jsonb_build_object('device', pocketterm.device_json(me));
end;
$$;

-- Push -----------------------------------------------------------------------------------------------------

-- POST /v1/push/:action, its body checked by the function. Returns {result} (the answer) and, for actions
-- that push, {notify: [{token, platform}]} or {activity: [tokens]} for the function to send.
create function public.pocketterm_push(p_token text, p_action text, p_body jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  v_token text := p_body ->> 'token';
  v_platform text := coalesce(p_body ->> 'platform', 'ios');
  v_session text := p_body ->> 'session';
  old text[];
  tokens pocketterm.activity_tokens[];
begin
  if me.id is null then return pocketterm.unauthorized(); end if;
  case p_action
    when 'register' then
      -- A phone has one push token: a new one takes the old one's place, and on Android the sessions it
      -- follows move with it.
      select coalesce(array_agg(token), '{}') into old from pocketterm.push_tokens
        where device = me.id and token <> v_token;
      delete from pocketterm.push_tokens where token = any(old);
      with moved as (
        delete from pocketterm.activity_tokens
          where device = me.id and platform = 'android' and token = any(old) returning session, ref
      )
      insert into pocketterm.activity_tokens (token, session, platform, device, ref)
        select distinct on (session) v_token, session, 'android', me.id, ref from moved
        on conflict (token, session) do update set ref = excluded.ref, device = excluded.device;
      insert into pocketterm.push_tokens (token, platform, label, device)
        values (v_token, v_platform, coalesce(p_body ->> 'label', ''), me.id)
        on conflict (token) do update set platform = excluded.platform, label = excluded.label,
          device = excluded.device;
      return jsonb_build_object('result', jsonb_build_object('ok', true));
    when 'unregister' then
      delete from pocketterm.push_tokens where case when v_token is null then device = me.id else token = v_token end;
      delete from pocketterm.activity_tokens where device = me.id or token = v_token;
      return jsonb_build_object('result', jsonb_build_object('ok', true));
    when 'notify' then
      return jsonb_build_object('notify', (select coalesce(jsonb_agg(jsonb_build_object('token', token,
        'platform', platform)), '[]'::jsonb) from pocketterm.push_tokens));
    when 'activity_register' then
      if not exists (select 1 from pocketterm.push_tokens where device = me.id) then
        return pocketterm.fail(409, 'push_off', 'Notifications are off on this phone: turn them on to follow a session.');
      end if;
      -- An iPhone's activity follows one session for good.
      delete from pocketterm.activity_tokens where token = v_token and (session = v_session or v_platform = 'ios');
      insert into pocketterm.activity_tokens (token, session, platform, device, ref)
        values (v_token, v_session, v_platform, me.id,
          case when v_platform = 'android' then p_body ->> 'ref' end);
      return jsonb_build_object('result', jsonb_build_object('ok', true));
    when 'activity_end' then
      if v_token is not null then
        delete from pocketterm.activity_tokens
          where token = v_token and device = me.id and (v_session is null or session = v_session);
      end if;
      return jsonb_build_object('result', jsonb_build_object('ok', true));
    when 'activity' then
      if me.role <> 'desktop' then return pocketterm.desktop_only(); end if;
      if pocketterm.held_by_other(split_part(v_session, '/', 1), me.id) then
        return pocketterm.fail(403, 'forbidden', 'Only the computer that added it can change it.');
      end if;
      select coalesce(array_agg(t), '{}') into tokens from pocketterm.activity_tokens t where t.session = v_session;
      -- An ended activity takes no more pushes.
      if p_body ->> 'state' = 'ended' then
        delete from pocketterm.activity_tokens where session = v_session;
      end if;
      return jsonb_build_object('activity', pocketterm.tokens_json(tokens));
    else
      return pocketterm.fail(404, 'not_found', 'No such endpoint on this server.');
  end case;
end;
$$;

-- The relay said the phone behind p_push_token is gone (410).
create function public.pocketterm_gone(p_push_token text)
returns void language sql security definer set search_path = '' as $$
  delete from pocketterm.push_tokens where token = p_push_token;
  delete from pocketterm.activity_tokens where token = p_push_token;
$$;

-- Housekeeping ---------------------------------------------------------------------------------------------

-- The function says where it answers, so pg_cron can call it (pocketterm.tick).
create function public.pocketterm_tick_url(p_url text)
returns void language sql security definer set search_path = '' as $$
  update pocketterm.server set tick_url = p_url where tick_url is distinct from p_url;
$$;

-- POST /v1/tick (pg_cron, every minute, with the tick secret): forgets expired codes and old failures,
-- returns the Live Activities of computers silent for 3 minutes to end, and the blobs over an hour old.
create function public.pocketterm_sweep(p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ending pocketterm.activity_tokens[] := '{}';
  d text;
begin
  if p_secret is distinct from (select tick_secret from pocketterm.server) then
    return pocketterm.fail(401, 'unauthorized', 'Not the tick.');
  end if;
  delete from pocketterm.pairing_codes where expires <= now();
  delete from pocketterm.redeem_failures where at < now() - interval '10 minutes';
  delete from pocketterm.blobs where created_at < now() - interval '1 hour';
  for d in
    select distinct split_part(t.session, '/', 1) from pocketterm.activity_tokens t
      left join pocketterm.desktops k on k.id = split_part(t.session, '/', 1)
      where k.id is null or k.seen_at < now() - interval '3 minutes'
  loop
    ending := ending || pocketterm.end_desktop(d);
  end loop;
  return jsonb_build_object('end', pocketterm.tokens_json(ending),
    'blobs', (select coalesce(jsonb_agg(name), '[]'::jsonb) from storage.objects
      where bucket_id = 'pocketterm-blobs' and created_at < now() - interval '1 hour'));
end;
$$;

-- The live channel ------------------------------------------------------------------------------------------

-- Realtime asks this for a private channel's every join and send: the topic is a computer's id and the token
-- (minted by the function, 10 minutes) names a device still signed in. A device signed out meanwhile is told
-- (pocketterm.tell_left) and refused at its next join or token refresh.
create function pocketterm.live_ok() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select realtime.topic()) ~ '^[a-z0-9]{8}$', false)
    and exists (select 1 from pocketterm.devices d where d.id = (select auth.jwt() ->> 'pt_device'));
$$;

grant usage on schema pocketterm to authenticated;
revoke all on all functions in schema pocketterm from public;
grant execute on function pocketterm.live_ok() to authenticated;

create policy pocketterm_live_receive on realtime.messages for select to authenticated
  using (realtime.messages.extension = 'broadcast' and (select pocketterm.live_ok()));
create policy pocketterm_live_send on realtime.messages for insert to authenticated
  with check (realtime.messages.extension = 'broadcast' and (select pocketterm.live_ok()));

-- Only the function (the service role) calls the pocketterm_* functions.
do $$
declare
  f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname like 'pocketterm\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;

-- Every minute, pg_cron has pg_net call the function's /v1/tick (once it said where it is).
create extension if not exists pg_net;
create extension if not exists pg_cron;

create function pocketterm.tick() returns void language plpgsql security definer set search_path = '' as $$
declare
  s pocketterm.server;
begin
  select * into s from pocketterm.server;
  if s.tick_url is null then return; end if;
  perform net.http_post(url := s.tick_url, body := '{}'::jsonb,
    headers := jsonb_build_object('content-type', 'application/json', 'x-pocketterm-tick', s.tick_secret));
end;
$$;

select cron.schedule('pocketterm-tick', '* * * * *', 'select pocketterm.tick()');
