-- =====================================================================
-- 404 Gaming Zone: sessions and bookings share the same machines
--                                         (TEST DATABASE ONLY for now)
--
-- Before this, a session was "a PS5" and a booking was "M3", so staff could
-- start a walk-in on a machine a customer had booked, and a customer could
-- book a machine somebody was playing on. Now:
--   * every session sits on a named machine
--   * the customer timetable shows a machine as taken while it is in use
--   * a booking is refused if the machine is in use at that time
--   * a confirmed booking is started as a session with one button, on its
--     machine, at its booked time, with the advance already counted
--   * ending that session marks the booking completed
-- Run after booking_tables.sql and half_hours.sql. Safe to re-run.
-- =====================================================================

-- ------------------------------------------------------------ MACHINES
-- The zone has 5 PS5, 1 PS4 and 1 Xbox. No PCs any more. Customers book the
-- PS5s online; the PS4 and Xbox are for walk-ins until the owners say otherwise.
alter table gz_machines add column if not exists bookable boolean not null default true;
insert into gz_machines (id, platform, games, sort, bookable) values
  ('PS4',  'ps4',  '[]', 6, false),
  ('XBOX', 'xbox', '[]', 7, false)
on conflict (id) do nothing;

-- ------------------------------------------------------------ SESSIONS
alter table gz_sessions add column if not exists advance_paid numeric not null default 0;
create index if not exists gz_sessions_machine_idx on gz_sessions (machine_id);

-- ---------------------------------- PUBLIC: WHAT IS TAKEN (now with sessions)
create or replace function gz_public_slots(p_from bigint, p_to bigint)
returns table (machine_id text, start_time bigint, end_time bigint, state text)
language sql
stable
security definer
set search_path = public
as $$
  select b.machine_id, b.start_time, b.end_time, b.state
    from gz_bookings b
   where b.state in ('pending','confirmed')
     and b.start_time < p_to and b.end_time > p_from
  union all
  select s.machine_id, s.start_time, s.end_time, 'playing'
    from gz_sessions s
   where s.machine_id is not null
     and s.start_time < p_to and s.end_time > p_from;
$$;

-- ------------------------------ A booking cannot land on a machine in use
-- Checked by a trigger so every way of creating a booking is covered.
create or replace function gz_bookings_guard_busy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.state in ('pending','confirmed') and exists (
       select 1 from gz_sessions s
        where s.machine_id = new.machine_id
          and coalesce(s.booking_id, '') <> new.id
          and s.start_time < new.end_time and s.end_time > new.start_time) then
    raise exception 'this slot was just taken — please pick another time';
  end if;
  return new;
end;
$$;
drop trigger if exists gz_bookings_guard_busy_trg on gz_bookings;
create trigger gz_bookings_guard_busy_trg
  before insert on gz_bookings
  for each row execute function gz_bookings_guard_busy();

-- --------------------------------------- STAFF: START A BOOKED SESSION
-- Turns a confirmed booking into a running session on its machine. The
-- clock runs from the BOOKED time, not from when the customer walked in.
create or replace function gz_start_booking(p_id text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  b      gz_bookings%rowtype;
  plat   text;
  who    text;
  busy   text;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  hrs    integer;
  rate   numeric;
  segs   jsonb := '[]'::jsonb;
  ppl    jsonb;
  sid    text := 'sess_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  i      integer;
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

  select platform into plat from gz_machines where id = b.machine_id;
  select name into who from profiles where id = auth.uid();
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
          rate, segs, coalesce(who, 'staff'), b.machine_id, b.id, b.paid);
  update gz_bookings set session_id = sid where id = b.id;
  return sid;
end;
$$;
revoke all on function gz_start_booking(text) from public, anon;
grant execute on function gz_start_booking(text) to authenticated;

-- ---------------------------------------------------- END A SESSION
-- Same as before, plus: the machine and booking are copied to history from
-- the session row itself, and a booked session completes its booking.
create or replace function public.gz_end_session(p_id text, p_record jsonb)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  method text    := nullif(p_record->>'pay_method','');
  cash   numeric := nullif(p_record->>'cash_amount','')::numeric;
  onl    numeric := nullif(p_record->>'online_amount','')::numeric;
  mach   text;
  bk     text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select machine_id, booking_id into mach, bk from gz_sessions where id = p_id;

  insert into gz_history (
    id, platform, game, player_count, player_names,
    start_time, end_time, paid_hours, hourly_rate,
    price_segments, revenue, ended_by,
    pay_method, cash_amount, online_amount, machine_id, booking_id
  ) values (
    p_record->>'id',
    p_record->>'platform',
    coalesce(p_record->>'game',''),
    coalesce((p_record->>'player_count')::int, 0),
    coalesce(p_record->'player_names', '[]'::jsonb),
    (p_record->>'start_time')::bigint,
    (p_record->>'end_time')::bigint,
    coalesce((p_record->>'paid_hours')::numeric, 1),
    coalesce((p_record->>'hourly_rate')::numeric, 0),
    coalesce(p_record->'price_segments', '[]'::jsonb),
    coalesce((p_record->>'revenue')::numeric, 0),
    p_record->>'ended_by',
    method,
    cash,
    onl,
    coalesce(mach, nullif(p_record->>'machine_id','')),
    coalesce(bk,   nullif(p_record->>'booking_id',''))
  )
  on conflict (id) do nothing;

  update sales
     set pay_method = coalesce(pay_method, method),
         settled_at = now()
   where gz_session_id = p_id
     and settled_at is null
     and coalesce(voided,false) = false;

  if bk is not null then
    update gz_bookings set state = 'completed' where id = bk and state = 'confirmed';
  end if;

  delete from gz_sessions where id = p_id;
  return true;
end;
$function$;
revoke all on function gz_end_session(text, jsonb) from public, anon;
grant execute on function gz_end_session(text, jsonb) to authenticated;
