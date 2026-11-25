-- =====================================================================
-- 404 Gaming Zone — bookings start their own session
-- Run AFTER link_sessions_bookings.sql. Safe to run twice.
--
-- Every minute the database looks for confirmed bookings whose time has
-- come and starts the session itself. Staff do not press anything.
--   * The timer runs from the BOOKED time, even if the customer is late.
--   * Only confirmed (payment approved) bookings start. A booking approved
--     late starts within a minute of the approval.
--   * If the machine is still in use by someone else, the booking waits
--     and starts as soon as that session is ended.
-- =====================================================================

-- The one place that turns a booking into a session. Not callable from outside.
create or replace function gz_booking_to_session(p_id text, p_who text)
returns text language plpgsql security definer set search_path = public as $$
declare
  b    gz_bookings%rowtype;
  plat text;
  hrs  integer;
  rate numeric;
  segs jsonb := '[]'::jsonb;
  ppl  jsonb;
  sid  text := 'sess_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  i    integer;
begin
  select * into b from gz_bookings where id = p_id for update;
  if not found or b.state <> 'confirmed' or b.session_id is not null then return null; end if;
  if exists (select 1 from gz_sessions where machine_id = b.machine_id) then return null; end if;

  select platform into plat from gz_machines where id = b.machine_id;
  hrs  := greatest(1, ((b.end_time - b.start_time) / 3600000)::integer);
  rate := round(b.total / hrs);
  for i in 0 .. hrs - 1 loop
    segs := segs || jsonb_build_array(jsonb_build_object('startTime', b.start_time + i * 3600000::bigint, 'rate', rate, 'hours', 1));
  end loop;
  ppl := jsonb_build_array(jsonb_build_object('name', b.customer_name, 'phone', '+92' || substr(b.customer_phone, 2)));
  for i in 2 .. b.players loop
    ppl := ppl || jsonb_build_array(jsonb_build_object('name', 'Player ' || i, 'phone', ''));
  end loop;

  insert into gz_sessions (id, platform, game, players, start_time, end_time, total_ms, paid_hours,
                           hourly_rate, price_segments, started_by, machine_id, booking_id, advance_paid)
  values (sid, coalesce(plat, 'ps5'), b.game, ppl, b.start_time, b.end_time, b.end_time - b.start_time, hrs,
          rate, segs, coalesce(p_who, 'auto'), b.machine_id, b.id, b.paid);
  update gz_bookings set session_id = sid where id = b.id;
  return sid;
end $$;
revoke all on function gz_booking_to_session(text, text) from public, anon, authenticated;

-- Staff button (kept: lets staff start up to 15 minutes early).
create or replace function gz_start_booking(p_id text)
returns text language plpgsql security definer set search_path = public as $$
declare
  b      gz_bookings%rowtype;
  who    text;
  busy   text;
  sid    text;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into b from gz_bookings where id = p_id for update;
  if not found then raise exception 'no such booking'; end if;
  if b.state = 'pending' then raise exception 'the payment has not been approved yet — ask an owner'; end if;
  if b.state <> 'confirmed' then raise exception 'this booking is %', b.state; end if;
  if b.session_id is not null then raise exception 'this booking has already been started'; end if;
  if now_ms < b.start_time - 15 * 60000 then raise exception 'too early — this booking starts later'; end if;
  if now_ms >= b.end_time then raise exception 'this booking''s time has already passed'; end if;
  select coalesce(players->0->>'name', 'another session') into busy
    from gz_sessions where machine_id = b.machine_id limit 1;
  if busy is not null then raise exception '% is still in use by %. End that session first.', b.machine_id, busy; end if;
  select name into who from profiles where id = auth.uid();
  sid := gz_booking_to_session(p_id, coalesce(who, 'staff'));
  if sid is null then raise exception 'could not start this booking'; end if;
  return sid;
end $$;
revoke all on function gz_start_booking(text) from public, anon;
grant execute on function gz_start_booking(text) to authenticated;

-- Start every booking that is due. Returns how many were started.
create or replace function gz_autostart_bookings()
returns integer language plpgsql security definer set search_path = public as $$
declare
  r      record;
  n      integer := 0;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  for r in select id from gz_bookings
            where state = 'confirmed' and session_id is null
              and start_time <= now_ms and end_time > now_ms
            order by start_time
  loop
    begin
      if gz_booking_to_session(r.id, 'auto') is not null then n := n + 1; end if;
    exception when others then null;   -- one bad booking must not stop the rest
    end;
  end loop;
  return n;
end $$;
revoke all on function gz_autostart_bookings() from public, anon;
grant execute on function gz_autostart_bookings() to authenticated;

-- Run it every minute, and keep the job log small.
create extension if not exists pg_cron;
select cron.schedule('gz-autostart', '* * * * *', 'select public.gz_autostart_bookings()');
select cron.schedule('gz-cron-tidy', '15 4 * * *', $$delete from cron.job_run_details where end_time < now() - interval '2 days'$$);

select jobname, schedule from cron.job where jobname in ('gz-autostart', 'gz-cron-tidy');
