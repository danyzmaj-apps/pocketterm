-- desktops.seen_at is the server's clock, never the computer's (supabase test db).
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'a@example.com', '{"provider": "github"}');

select set_config('role', 'authenticated', true),
       set_config('request.jwt.claims', jsonb_build_object('sub', '00000000-0000-0000-0000-00000000000a', 'role', 'authenticated')::text, true);

-- A computer whose clock is a day behind.
insert into public.desktops (id, name, platform, seen_at) values ('abcdefgh', 'Mac', 'macos', now() - interval '1 day');
select is((select seen_at from public.desktops where id = 'abcdefgh'), now(), 'a new computer is seen now');

-- Its beat: an upsert of what it sends, seen_at left out.
update public.desktops set seen_at = '2000-01-01' where id = 'abcdefgh';
insert into public.desktops (id, name, platform) values ('abcdefgh', 'Mac', 'macos')
  on conflict (user_id, id) do update set name = excluded.name, platform = excluded.platform;
select is((select seen_at from public.desktops where id = 'abcdefgh'), now(), 'each beat is seen now');

select * from finish();
rollback;
