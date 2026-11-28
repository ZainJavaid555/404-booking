-- =====================================================================
-- 404 Gaming Zone — start a booking a little early or a little late
-- Run AFTER player_names.sql. Safe to run twice.
--
-- The whole slot moves, so the customer keeps the full time they paid for.
-- Rules, all enforced here and not just on the screen:
--   * at most 30 minutes away from the time the customer first booked
--   * never on top of another booking or a session still running
--   * never outside opening hours (9 AM to 3 AM)
--   * staff may shift a booking that has not started; once its session is
--     running only an owner may shift it
--   * every shift is written down with who did it
-- =====================================================================
alter table gz_bookings add column if not exists orig_start bigint;   -- the time first booked; null = never shifted

create table if not exists gz_booking_shifts (
  id         bigserial primary key,
  booking_id text not null,
  minutes    integer not null,                 -- minus = earlier, plus = later
  from_start bigint not null,
  to_start   bigint not null,
  by_uid     uuid,
  by_name    text,
  at         timestamptz not null default now()
);
alter table gz_booking_shifts enable row level security;
drop policy if exists "booking_shifts_read" on gz_booking_shifts;
create policy "booking_shifts_read" on gz_booking_shifts for select using (auth.uid() is not null);
revoke all on gz_booking_shifts from anon;

create or replace function gz_shift_booking(p_id text, p_minutes integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b        gz_bookings%rowtype;
  now_ms   bigint := (extract(epoch from now()) * 1000)::bigint;
  delta    bigint := coalesce(p_minutes, 0)::bigint * 60000;
  base     bigint;
  ns       bigint;
  ne       bigint;
  mins_open integer;
  other    text;
  who      text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if coalesce(p_minutes, 0) = 0 then raise exception 'choose how many minutes'; end if;
  select * into b from gz_bookings where id = p_id for update;
  if not found then raise exception 'no such booking'; end if;
  if b.state not in ('pending', 'confirmed') then raise exception 'this booking is %', b.state; end if;

  if b.session_id is not null and not is_owner() then
    raise exception 'this session is already running — only an owner can shift it now';
  end if;
  if b.session_id is null and p_minutes > 0 and now_ms >= b.start_time and not is_owner() then
    raise exception 'the booked time has already come — only an owner can move it later now';
  end if;

  base := coalesce(b.orig_start, b.start_time);
  ns := b.start_time + delta;
  ne := b.end_time + delta;
  if abs(ns - base) > 30 * 60000 then
    raise exception 'a booking can move at most 30 minutes from the time the customer booked';
  end if;
  if b.session_id is null and ns < now_ms - 60000 then
    raise exception 'that start time has already passed';
  end if;

  -- opening hours: minutes since 9 AM Pakistan time on that business day
  mins_open := ((((ns + 5 * 3600000) / 60000) - 540) % 1440)::integer;
  if mins_open < 0 then mins_open := mins_open + 1440; end if;
  if mins_open + ((ne - ns) / 60000) > 18 * 60 then
    raise exception 'that would go outside opening hours (9 AM to 3 AM)';
  end if;

  select customer_name into other from gz_bookings
   where machine_id = b.machine_id and id <> b.id and state in ('pending', 'confirmed')
     and start_time < ne and end_time > ns limit 1;
  if other is not null then raise exception '% is booked by % at that time', b.machine_id, other; end if;

  select coalesce(players->0->>'name', 'another session') into other from gz_sessions
   where machine_id = b.machine_id and coalesce(booking_id, '') <> b.id
     and start_time < ne and greatest(end_time, now_ms) > ns limit 1;
  if other is not null then raise exception '% is in use by % at that time', b.machine_id, other; end if;

  update gz_bookings set start_time = ns, end_time = ne, orig_start = base where id = b.id;

  if b.session_id is not null then
    update gz_sessions
       set start_time = start_time + delta, end_time = end_time + delta,
           price_segments = (select coalesce(jsonb_agg(
               case when seg ? 'startTime' then jsonb_set(seg, '{startTime}', to_jsonb((seg->>'startTime')::bigint + delta)) else seg end
               order by ord), '[]'::jsonb)
             from jsonb_array_elements(price_segments) with ordinality as t(seg, ord))
     where id = b.session_id;
  end if;

  select name into who from profiles where id = auth.uid();
  insert into gz_booking_shifts (booking_id, minutes, from_start, to_start, by_uid, by_name)
  values (b.id, p_minutes, b.start_time, ns, auth.uid(), who);

  return jsonb_build_object('start_time', ns, 'end_time', ne);
end $$;
revoke all on function gz_shift_booking(text, integer) from public, anon;
grant execute on function gz_shift_booking(text, integer) to authenticated;

select 'gz_shift_booking' as "check", count(*)::text as installed from pg_proc where proname = 'gz_shift_booking'
union all select 'gz_booking_shifts', count(*)::text from information_schema.tables where table_name = 'gz_booking_shifts';
