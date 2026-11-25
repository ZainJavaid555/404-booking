-- =====================================================================
-- 404 Gaming Zone — names of every player on a booking
-- Run AFTER auto_start.sql. Safe to run twice.
--
-- The customer types a name for each extra player (mobile is optional).
-- The names are kept on the booking and copied onto the session when it
-- starts, so staff see real names instead of "Player 2".
-- =====================================================================
alter table gz_bookings add column if not exists player_list jsonb not null default '[]'::jsonb;

-- Same as gz_create_booking, plus the other players. p_player_list is
-- [{"name":"Ali","phone":"03001234567"}, ...] for players 2, 3, ... only.
create or replace function gz_create_booking_v2(
  p_machine text, p_game text, p_start bigint, p_hours integer, p_players integer,
  p_name text, p_phone text, p_amount numeric, p_proof_path text, p_player_list jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  res   jsonb;
  clean jsonb := '[]'::jsonb;
  el    jsonb;
  nm    text;
  ph    text;
begin
  if p_player_list is null or jsonb_typeof(p_player_list) <> 'array' then p_player_list := '[]'::jsonb; end if;
  if jsonb_array_length(p_player_list) <> greatest(coalesce(p_players, 1) - 1, 0) then
    raise exception 'please enter a name for every player';
  end if;
  for el in select * from jsonb_array_elements(p_player_list) loop
    nm := left(trim(coalesce(el->>'name', '')), 60);
    ph := regexp_replace(coalesce(el->>'phone', ''), '[\s-]', '', 'g');
    if length(nm) < 2 then raise exception 'please enter a name for every player'; end if;
    if ph <> '' and ph !~ '^03[0-9]{9}$' then raise exception 'a player''s mobile number is not valid — use 03XXXXXXXXX or leave it empty'; end if;
    clean := clean || jsonb_build_array(jsonb_build_object('name', nm, 'phone', ph));
  end loop;

  res := gz_create_booking(p_machine, p_game, p_start, p_hours, p_players, p_name, p_phone, p_amount, p_proof_path, null);
  update gz_bookings set player_list = clean where id = res->>'id';
  return res;
end $$;
revoke all on function gz_create_booking_v2(text, text, bigint, integer, integer, text, text, numeric, text, jsonb) from public;
grant execute on function gz_create_booking_v2(text, text, bigint, integer, integer, text, text, numeric, text, jsonb) to anon, authenticated;

-- Booking -> session, now with the real names.
create or replace function gz_booking_to_session(p_id text, p_who text)
returns text language plpgsql security definer set search_path = public as $$
declare
  b    gz_bookings%rowtype;
  plat text;
  hrs  integer;
  rate numeric;
  segs jsonb := '[]'::jsonb;
  ppl  jsonb;
  el   jsonb;
  sid  text := 'sess_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  i    integer;
  n    integer := 1;
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
  for el in select * from jsonb_array_elements(coalesce(b.player_list, '[]'::jsonb)) loop
    exit when n >= b.players;
    ppl := ppl || jsonb_build_array(jsonb_build_object('name', el->>'name',
             'phone', case when coalesce(el->>'phone', '') <> '' then '+92' || substr(el->>'phone', 2) else '' end));
    n := n + 1;
  end loop;
  for i in n + 1 .. b.players loop
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

select 'player_list column' as "check", count(*)::text as installed from information_schema.columns where table_name = 'gz_bookings' and column_name = 'player_list'
union all select 'gz_create_booking_v2', count(*)::text from pg_proc where proname = 'gz_create_booking_v2';
