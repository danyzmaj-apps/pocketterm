-- Row level security: every account sees and changes only its own rows (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000b', 'b@example.com', '{"provider": "github"}');

create function pg_temp.sign_in(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', id, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.sign_out() returns void language sql as $$
  select set_config('role', 'none', true), set_config('request.jwt.claims', '', true)
$$;

-- B's rows, made by the server.
insert into public.push_devices (token, user_id) values ('b-phone', '00000000-0000-0000-0000-00000000000b');
insert into public.activity_tokens (token, user_id, session) values ('b-activity', '00000000-0000-0000-0000-00000000000b', 's');
insert into public.allowed_signups (email) values ('friend@example.com');
insert into public.pairing_failures (ip) values ('192.0.2.1');
insert into public.pairing_codes (id, code_hash, user_id, created_by, reusable, expires_at) values
  ('00000000-0000-0000-0000-0000000003b0', 'b-code', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', true, now() + interval '1 day');
insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000b/b.png');
insert into public.desktops (user_id, id, name, platform) values ('00000000-0000-0000-0000-00000000000b', 'bbbbbbbb', 'B''s PC', 'windows');

select pg_temp.sign_in('00000000-0000-0000-0000-00000000000a');

-- Server-only tables: nothing to see, nothing to write.
select is((select count(*) from public.push_devices), 0::bigint, 'phones are server-only');
select is((select count(*) from public.activity_tokens), 0::bigint, 'followed sessions are server-only');
select is((select count(*) from public.allowed_signups), 0::bigint, 'the sign-up list is server-only');
select is((select count(*) from public.pairing_failures), 0::bigint, 'the pairing throttle is server-only');
delete from public.push_devices where token = 'b-phone';
select throws_ok($$insert into public.push_devices (token, user_id) values ('a-phone', '00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'phones register only through functions/push');
select throws_ok($$insert into public.activity_tokens (token, user_id, session) values ('a-activity', '00000000-0000-0000-0000-00000000000a', 's')$$,
  '42501', null, 'sessions are followed only through functions/push');
select throws_ok($$insert into public.allowed_signups (email) values ('me@example.com')$$, '42501', null,
  'nobody signed in can let people in');

-- Pairing codes: only one's own, without the hash, and only revoking.
select is((select count(*) from public.pairing_codes), 0::bigint, 'B''s codes are hidden');
update public.pairing_codes set revoked_at = now() where id = '00000000-0000-0000-0000-0000000003b0';
select throws_ok('select code_hash from public.pairing_codes', '42501', null, 'nobody reads a code''s hash');
select throws_ok($$insert into public.pairing_codes (code_hash, user_id, created_by, expires_at)
  values ('mine', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000a', now() + interval '1 day')$$,
  '42501', null, 'codes are made only by functions/pair');

-- Computers: one's own, with a well-formed id, a name and a known platform.
select is((select count(*) from public.desktops), 0::bigint, 'B''s computers are hidden');
select lives_ok($$insert into public.desktops (id, name, platform) values ('a1b2c3d4', 'A''s Mac', 'macos')$$,
  'A registers a computer');
select throws_ok($$insert into public.desktops (id, name, platform) values ('A1B2C3D4', 'x', 'macos')$$,
  '23514', null, 'a computer id is 8 lowercase letters and digits');
select throws_ok($$insert into public.desktops (id, name, platform) values ('e5f6g7h8', 'x', 'linux')$$,
  '23514', null, 'a computer is a Mac or a Windows PC');
select throws_ok($$insert into public.desktops (id, name, platform) values ('i9j0k1l2', '', 'windows')$$,
  '23514', null, 'a computer has a name');

-- Storage: one's own folder of the terminal bucket.
select is((select count(*) from storage.objects), 0::bigint, 'B''s images are hidden');
select lives_ok($$insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000a/a.png')$$,
  'A uploads into their own folder');
select throws_ok($$insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000b/x.png')$$,
  '42501', null, 'but not into B''s');

-- Nothing for anyone signed out.
select pg_temp.sign_out();
select set_config('role', 'anon', true);
select is((select count(*) from public.push_devices) + (select count(*) from public.activity_tokens), 0::bigint,
  'signed out, nothing is visible');
select throws_ok('select id from public.pairing_codes', '42501', null, 'not even which codes exist');
select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'execute'), 'signed out, no account to delete');
select ok(not has_function_privilege('anon', 'public.reviewer_access_active()', 'execute'), 'or access to check');

-- B's rows came through A's attempts untouched.
select pg_temp.sign_out();
select is((select count(*) from public.push_devices where token = 'b-phone'), 1::bigint, 'B''s phone is still registered');
select is((select revoked_at from public.pairing_codes where code_hash = 'b-code'), null, 'B''s code still works');

select * from finish();
rollback;
