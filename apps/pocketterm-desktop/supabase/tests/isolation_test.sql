-- The reviewer demo account and a second account reach none of the owner's
-- rows, images or terminal topic (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000b', 'second@example.com', '{"provider": "github"}'),
  ('00000000-0000-0000-0000-00000000000d', 'reviewer@x.pocketterm.invalid', '{"provider": "email", "pocketterm_demo": true}');

create function pg_temp.sign_in(id uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', jsonb_build_object('sub', id, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.sign_out() returns void language sql as $$
  select set_config('role', 'none', true), set_config('request.jwt.claims', '', true)
$$;

-- The owner's rows, made by the server; a reviewer code keeps the demo's access open.
insert into public.push_devices (token, user_id, key) values ('owner-phone', '00000000-0000-0000-0000-00000000000a', 'k');
insert into public.activity_tokens (token, user_id, session) values ('owner-activity', '00000000-0000-0000-0000-00000000000a', 's');
insert into public.pairing_codes (id, code_hash, user_id, created_by, reusable, expires_at) values
  ('00000000-0000-0000-0000-0000000003a0', 'review', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000a', true, now() + interval '30 days');
insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000a/t.png');

create function pg_temp.owner_rows() returns bigint language sql security definer as $$
  select (select count(*) from public.push_devices where user_id = '00000000-0000-0000-0000-00000000000a')
       + (select count(*) from public.activity_tokens where user_id = '00000000-0000-0000-0000-00000000000a')
       + (select count(*) from public.pairing_codes where code_hash = 'review' and revoked_at is null)
       + (select count(*) from storage.objects where name like '00000000-0000-0000-0000-00000000000a/%')
$$;

-- The same attempts as the demo account and as the second account.
create function pg_temp.attempts(who uuid, label text) returns setof text language plpgsql as $fn$
begin
  perform pg_temp.sign_in(who);
  return next is((select count(*) from public.push_devices) + (select count(*) from public.activity_tokens)
    + (select count(*) from public.pairing_codes), 0::bigint,
    label || ' sees none of the owner''s rows');
  return next is((select count(*) from storage.objects), 0::bigint, label || ' sees none of the owner''s images');
  update public.pairing_codes set revoked_at = now() where id = '00000000-0000-0000-0000-0000000003a0';
  delete from public.push_devices where token = 'owner-phone';
  delete from public.activity_tokens where token = 'owner-activity';
  return next throws_ok($$insert into public.push_devices (token, user_id, key) values ('x', '00000000-0000-0000-0000-00000000000a', 'k')$$,
    '42501', null, label || ' can''t register a phone as the owner');
  return next throws_ok($$insert into storage.objects (bucket_id, name) values ('terminal', '00000000-0000-0000-0000-00000000000a/x.png')$$,
    '42501', null, label || ' can''t upload into the owner''s folder');
  -- Terminal from the phone: the owner's private topic, to listen or to send.
  perform set_config('realtime.topic', 'terminal:00000000-0000-0000-0000-00000000000a', true);
  return next is((select count(*) from realtime.messages), 0::bigint, label || ' hears nothing on the owner''s terminal topic');
  return next throws_ok($$insert into realtime.messages (topic, extension, payload, event, private)
    values ('terminal:00000000-0000-0000-0000-00000000000a', 'broadcast', '{}', 'type', true)$$,
    '42501', null, label || ' can''t send on the owner''s terminal topic');
  perform set_config('realtime.topic', 'terminal:' || who::text, true);
  return next lives_ok(format($$insert into realtime.messages (topic, extension, payload, event, private)
    values ('terminal:%s', 'broadcast', '{}', 'type', true)$$, who),
    label || ' can send on its own terminal topic');
  perform pg_temp.sign_out();
  return next is(pg_temp.owner_rows(), 4::bigint, label || ' changed none of the owner''s rows or images');
end $fn$;

select * from pg_temp.attempts('00000000-0000-0000-0000-00000000000d', 'the demo account');
select * from pg_temp.attempts('00000000-0000-0000-0000-00000000000b', 'a second account');

-- Signed out: nothing of anyone's, and no terminal topic.
select set_config('role', 'anon', true);
select is((select count(*) from public.push_devices) + (select count(*) from storage.objects), 0::bigint, 'signed out sees nothing');
select set_config('realtime.topic', 'terminal:00000000-0000-0000-0000-00000000000a', true);
select throws_ok($$insert into realtime.messages (topic, extension, payload, event, private)
  values ('terminal:00000000-0000-0000-0000-00000000000a', 'broadcast', '{}', 'type', true)$$,
  '42501', null, 'signed out can''t send on any terminal topic');
select pg_temp.sign_out();
select is(pg_temp.owner_rows(), 4::bigint, 'the owner''s rows and images are all still there');

select * from finish();
rollback;
