-- seen_at by the server's clock, whatever a computer sends: the phone tells
-- "Online" from it, and a computer's clock can be minutes off.
create function public.desktops_stamp_seen_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.seen_at := now();
  return new;
end;
$$;

create trigger stamp_seen_at before insert or update on public.desktops
  for each row execute function public.desktops_stamp_seen_at();
