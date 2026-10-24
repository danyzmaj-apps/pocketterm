-- Live Activities stay fresh while their computer checks in. An iPhone's Live Activity goes stale 3 minutes after
-- its last push, and an idle session's state doesn't change: each iPhone activity token keeps the last state it
-- was pushed (the plain {state, since, kind?} the relay already gets) and when, and PUT /v1/desktops/:id hands
-- the function the ones of that computer pushed 110 seconds ago or more to send again, quietly. An ended activity
-- is forgotten as before, so it never comes back; a computer that stops checking in still has them ended by the
-- tick after 3 minutes. Android states are sealed by the computer and never kept.

alter table pocketterm.activity_tokens
  add column live jsonb,
  add column pushed_at timestamptz;

-- PUT /v1/desktops/:id: not one another computer holds (pocketterm.held_by_other). With the computer's row, under
-- refresh, the iPhones following one of its sessions whose last state went out 110 seconds ago or more:
-- [{token, state}], stamped as sent now (the function sends them and leaves refresh out of its answer).
create or replace function public.pocketterm_put_desktop(p_token text, p_id text, p_name text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  d pocketterm.desktops;
  due jsonb;
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
  with sent as (
    update pocketterm.activity_tokens t set pushed_at = now()
      where split_part(t.session, '/', 1) = p_id and t.platform = 'ios' and t.live is not null
        and (t.pushed_at is null or t.pushed_at <= now() - interval '110 seconds')
      returning t.token, t.live
  )
  select coalesce(jsonb_agg(jsonb_build_object('token', token, 'state', live)), '[]'::jsonb) into due from sent;
  return pocketterm.desktop_json(d) || jsonb_build_object('refresh', due);
end;
$$;

-- POST /v1/push/:action, its body checked by the function. Returns {result} (the answer) and, for actions
-- that push, {notify: [{token, platform}]} or {activity: [tokens], live: {state, since, kind?}} for the function
-- to send; the iPhones' tokens keep live (but an end) for the refresh in pocketterm_put_desktop.
create or replace function public.pocketterm_push(p_token text, p_action text, p_body jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me pocketterm.devices := pocketterm.auth(p_token);
  v_token text := p_body ->> 'token';
  v_platform text := coalesce(p_body ->> 'platform', 'ios');
  v_session text := p_body ->> 'session';
  old text[];
  tokens pocketterm.activity_tokens[];
  v_live jsonb;
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
      v_live := jsonb_build_object('state', p_body ->> 'state', 'since', floor(extract(epoch from now()))::bigint)
        || case when p_body ->> 'state' = 'needs' and p_body ->> 'kind' is not null
          then jsonb_build_object('kind', p_body ->> 'kind') else '{}'::jsonb end;
      select coalesce(array_agg(t), '{}') into tokens from pocketterm.activity_tokens t where t.session = v_session;
      -- An ended activity takes no more pushes.
      if p_body ->> 'state' = 'ended' then
        delete from pocketterm.activity_tokens where session = v_session;
      else
        update pocketterm.activity_tokens set live = v_live, pushed_at = now()
          where session = v_session and platform = 'ios';
      end if;
      return jsonb_build_object('activity', pocketterm.tokens_json(tokens), 'live', v_live);
    else
      return pocketterm.fail(404, 'not_found', 'No such endpoint on this server.');
  end case;
end;
$$;
