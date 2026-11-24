-- =====================================================================
-- 404 Gaming Zone: booking system ("Build Your Own Slot")  — DRAFT
--
-- Adds machines, bookings and payment proofs on top of the existing
-- database (see full_schema.sql). TEST DATABASE ONLY for now.
-- Safe to re-run: everything is guarded with IF NOT EXISTS / OR REPLACE.
--
-- How it fits the plan:
--   customer picks a slot and uploads proof  -> booking is 'pending' (slot locked)
--   owner checks the account and approves    -> 'confirmed'
--   owner declines                           -> 'declined'  (slot is free again)
--
-- Customers are NOT signed in. They never touch the tables directly; they
-- can only call the three public functions at the bottom, which check
-- everything inside the database. Staff and owners sign in as they do today.
-- =====================================================================

create extension if not exists btree_gist;   -- needed for the no-overlap rule

-- ---------------------------------------------------------------- MACHINES
-- The current system only knows "a PS5". Booking needs to know WHICH one.
create table if not exists gz_machines (
  id         text primary key,                       -- 'M1', 'M2', ...
  platform   text not null default 'ps5',
  games      jsonb not null default '[]'::jsonb,     -- ["GTA 6","FC 26", ...]
  active     boolean not null default true,
  sort       integer not null default 0,
  updated_at timestamptz default now()
);

-- ---------------------------------------------------------------- BOOKINGS
create sequence if not exists gz_booking_no_seq start 1001;

create table if not exists gz_bookings (
  id             text primary key default ('bk_' || replace(gen_random_uuid()::text, '-', '')),
  booking_no     integer not null default nextval('gz_booking_no_seq') unique,
  machine_id     text not null references gz_machines(id),
  game           text not null default '',
  start_time     bigint not null,                    -- ms since epoch, same as gz_sessions
  end_time       bigint not null,
  players        integer not null default 2 check (players between 1 and 4),
  customer_name  text not null check (length(trim(customer_name)) >= 2),
  customer_phone text not null check (customer_phone ~ '^03[0-9]{9}$'),
  total          numeric not null check (total >= 0),
  paid           numeric not null default 0 check (paid >= 0),
  state          text not null default 'pending'
                 check (state in ('pending','confirmed','declined','cancelled','released','completed')),
  source         text not null default 'website' check (source in ('website','walkin','manual')),
  decline_reason text,
  decided_by     text,
  decided_at     timestamptz,
  session_id     text,                               -- set when the session actually starts
  created_at     timestamptz default now(),
  constraint gz_bookings_time_chk  check (end_time > start_time),
  constraint gz_bookings_hours_chk check ((end_time - start_time) % 3600000 = 0),
  -- The rule that makes double-booking impossible, even if two customers
  -- press the button in the same second: two LOCKED bookings on one machine
  -- may never overlap. Declined / cancelled / released ones do not count.
  constraint gz_bookings_no_overlap exclude using gist (
    machine_id with =,
    int8range(start_time, end_time) with &&
  ) where (state in ('pending','confirmed'))
);

create index if not exists gz_bookings_start_idx on gz_bookings (start_time);
create index if not exists gz_bookings_state_idx on gz_bookings (state, start_time);
create index if not exists gz_bookings_phone_idx on gz_bookings (customer_phone);

-- ---------------------------------------------------------- PAYMENT PROOFS
create table if not exists gz_booking_payments (
  id         bigserial primary key,
  booking_id text not null references gz_bookings(id),
  amount     numeric not null check (amount > 0),
  proof_path text,                                   -- file in Storage bucket 'payment-proofs'
  txn_id     text,                                   -- transaction ID read from the screenshot
  ai_pass    boolean,                                -- stage 2: result of the AI pre-check
  ai_read    jsonb,                                  -- stage 2: what the AI read
  status     text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at timestamptz default now()
);

-- One receipt cannot pay for two bookings.
create unique index if not exists gz_booking_payments_txn_uniq
  on gz_booking_payments (txn_id) where txn_id is not null and status <> 'declined';
create index if not exists gz_booking_payments_booking_idx on gz_booking_payments (booking_id);

-- Sessions learn which machine and which booking they belong to.
alter table gz_sessions add column if not exists machine_id text;
alter table gz_sessions add column if not exists booking_id text;
alter table gz_history  add column if not exists machine_id text;
alter table gz_history  add column if not exists booking_id text;

-- ------------------------------------------------------------------ RULES
alter table gz_machines         enable row level security;
alter table gz_bookings         enable row level security;
alter table gz_booking_payments enable row level security;

drop policy if exists "gz_machines_read"        on gz_machines;
drop policy if exists "gz_machines_owner_write" on gz_machines;
drop policy if exists "gz_bookings_team_read"   on gz_bookings;
drop policy if exists "gz_payments_owner_read"  on gz_booking_payments;

-- Anyone may see the machines and their games (it is the public menu).
create policy "gz_machines_read" on gz_machines for select using (true);
create policy "gz_machines_owner_write" on gz_machines for all
  using (is_owner()) with check (is_owner());

-- Staff and owners see bookings. Nobody inserts or updates directly: every
-- change goes through a function below, so the rules cannot be skipped.
create policy "gz_bookings_team_read" on gz_bookings for select
  using (auth.uid() is not null);

-- Payment proofs are for owners only.
create policy "gz_payments_owner_read" on gz_booking_payments for select
  using (is_owner());

-- ----------------------------------------------------------------- PRICE
-- Rates live in gz_settings (value -> 'booking'), so owners can change them
-- without a developer. Defaults: Rs 400/hour for 2 players, +Rs 100 per
-- extra player per hour, 50% advance.
create or replace function gz_booking_price(p_hours integer, p_players integer)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select p_hours * (
           coalesce((select (value->'booking'->>'rate')::numeric  from gz_settings where id = 'main'), 400)
         + greatest(0, p_players - 2)
           * coalesce((select (value->'booking'->>'extra')::numeric from gz_settings where id = 'main'), 100)
         );
$$;

-- ------------------------------------------------- PUBLIC: WHAT IS TAKEN
-- Returns locked slots only: machine and times. No names, no phones.
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
     and b.start_time < p_to and b.end_time > p_from;
$$;

-- --------------------------------------------- PUBLIC: CREATE A BOOKING
create or replace function gz_create_booking(
  p_machine text, p_game text, p_start bigint, p_hours integer, p_players integer,
  p_name text, p_phone text, p_amount numeric, p_proof_path text, p_txn text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m          gz_machines%rowtype;
  local_ts   timestamp;
  mins_open  integer;      -- minutes since 9 AM on that business day
  price      numeric;
  need       numeric;
  new_id     text;
  new_no     integer;
begin
  select * into m from gz_machines where id = p_machine and active;
  if not found then raise exception 'that machine is not available'; end if;
  if not (m.games ? p_game) then raise exception 'that game is not on %', p_machine; end if;

  if p_hours is null or p_hours < 1 or p_hours > 6 then raise exception 'book between 1 and 6 hours'; end if;
  if p_players is null or p_players < 1 or p_players > 4 then raise exception 'between 1 and 4 players'; end if;
  if p_start % 3600000 <> 0 then raise exception 'slots start on the hour'; end if;
  if p_start < (extract(epoch from now()) * 1000)::bigint - 5 * 60000 then
    raise exception 'that time has already passed';
  end if;
  if p_start > (extract(epoch from now()) * 1000)::bigint + 14 * 86400000::bigint then
    raise exception 'bookings open 14 days ahead';
  end if;

  -- Open 9 AM to 3 AM, Lahore time. A slot must start and END inside that.
  local_ts  := to_timestamp(p_start / 1000.0) at time zone 'Asia/Karachi';
  mins_open := ((extract(hour from local_ts)::int - 9 + 24) % 24) * 60;
  if mins_open + p_hours * 60 > 18 * 60 then
    raise exception 'we are open 9 AM to 3 AM';
  end if;

  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'enter your name'; end if;
  if coalesce(p_phone, '') !~ '^03[0-9]{9}$' then
    raise exception 'enter a valid mobile number, like 03001234567';
  end if;
  if coalesce(p_proof_path, '') = '' then raise exception 'upload the payment screenshot'; end if;

  price := gz_booking_price(p_hours, p_players);
  need  := ceil(price * coalesce((select (value->'booking'->>'advance_pct')::numeric
                                    from gz_settings where id = 'main'), 50) / 100.0);
  if coalesce(p_amount, 0) < need then
    raise exception 'pay at least Rs % to book', need;
  end if;
  if p_amount > price then raise exception 'that is more than the total (Rs %)', price; end if;

  begin
    insert into gz_bookings (machine_id, game, start_time, end_time, players,
                             customer_name, customer_phone, total, paid, state, source)
    values (p_machine, p_game, p_start, p_start + p_hours * 3600000::bigint, p_players,
            trim(p_name), p_phone, price, 0, 'pending', 'website')
    returning id, booking_no into new_id, new_no;
  exception when exclusion_violation then
    raise exception 'this slot was just taken — please pick another time';
  end;

  begin
    insert into gz_booking_payments (booking_id, amount, proof_path, txn_id)
    values (new_id, p_amount, p_proof_path, nullif(trim(coalesce(p_txn, '')), ''));
  exception when unique_violation then
    raise exception 'this payment receipt has already been used';
  end;

  return jsonb_build_object('id', new_id, 'booking_no', new_no, 'total', price,
                            'paid_claimed', p_amount, 'state', 'pending');
end;
$$;

-- ------------------------------------------- PUBLIC: CHECK MY BOOKING
-- The customer needs both the booking number and their phone, so numbers
-- cannot be guessed to read other people's bookings.
create or replace function gz_booking_status(p_booking_no integer, p_phone text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('booking_no', b.booking_no, 'machine_id', b.machine_id, 'game', b.game,
                            'start_time', b.start_time, 'end_time', b.end_time, 'players', b.players,
                            'total', b.total, 'paid', b.paid, 'state', b.state,
                            'decline_reason', b.decline_reason)
    from gz_bookings b
   where b.booking_no = p_booking_no and b.customer_phone = p_phone;
$$;

-- ------------------------------------------- OWNER: APPROVE OR DECLINE
create or replace function gz_decide_booking(p_id text, p_approve boolean, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  who text;
  amt numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can approve or decline a payment'; end if;
  if not exists (select 1 from gz_bookings where id = p_id and state = 'pending') then
    raise exception 'that booking is not waiting for a decision';
  end if;
  select name into who from profiles where id = auth.uid();

  if p_approve then
    select coalesce(sum(amount), 0) into amt from gz_booking_payments
     where booking_id = p_id and status = 'pending';
    update gz_booking_payments set status = 'approved' where booking_id = p_id and status = 'pending';
    update gz_bookings set state = 'confirmed', paid = amt, decided_by = who, decided_at = now()
     where id = p_id;
    return 'confirmed';
  end if;

  if coalesce(trim(p_reason), '') = '' then raise exception 'a reason is required to decline'; end if;
  update gz_booking_payments set status = 'declined' where booking_id = p_id and status = 'pending';
  update gz_bookings set state = 'declined', decline_reason = p_reason, decided_by = who, decided_at = now()
   where id = p_id;
  return 'declined';
end;
$$;

-- ------------------------------------------- STAFF: RELEASE A LATE SEAT
-- Allowed only when the customer is 30+ minutes late, has not arrived
-- (no session started) and has not paid in full.
create or replace function gz_release_booking(p_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  b gz_bookings%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into b from gz_bookings where id = p_id and state = 'confirmed';
  if not found then raise exception 'that booking cannot be released'; end if;
  if b.session_id is not null then raise exception 'the customer has already started'; end if;
  if b.paid >= b.total then raise exception 'paid in full — the seat is held for the whole slot'; end if;
  if (extract(epoch from now()) * 1000)::bigint < b.start_time + 30 * 60000 then
    raise exception 'wait until the customer is 30 minutes late';
  end if;
  update gz_bookings set state = 'released', decided_at = now() where id = p_id;
  return true;
end;
$$;

-- ------------------------------------------------------------ PERMISSIONS
revoke all on function gz_booking_price(integer, integer)            from public;
revoke all on function gz_public_slots(bigint, bigint)               from public;
revoke all on function gz_create_booking(text, text, bigint, integer, integer, text, text, numeric, text, text) from public;
revoke all on function gz_booking_status(integer, text)              from public;
revoke all on function gz_decide_booking(text, boolean, text)        from public;
revoke all on function gz_release_booking(text)                      from public;

grant execute on function gz_booking_price(integer, integer)         to anon, authenticated;
grant execute on function gz_public_slots(bigint, bigint)            to anon, authenticated;
grant execute on function gz_create_booking(text, text, bigint, integer, integer, text, text, numeric, text, text) to anon, authenticated;
grant execute on function gz_booking_status(integer, text)           to anon, authenticated;
grant execute on function gz_decide_booking(text, boolean, text)     to authenticated;
grant execute on function gz_release_booking(text)                   to authenticated;

-- --------------------------------------------------------------- REALTIME
do $$
begin
  begin execute 'alter publication supabase_realtime add table gz_bookings'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table gz_machines'; exception when others then null; end;
end $$;

-- ------------------------------------------------------------ SAMPLE DATA
-- Placeholder machines so the test site has something to show. The real
-- game list per machine comes from the owners.
insert into gz_machines (id, platform, games, sort) values
  ('M1', 'ps5', '["GTA 6","FC 26","Tekken 8"]', 1),
  ('M2', 'ps5', '["GTA 6","FC 26","Tekken 8"]', 2),
  ('M3', 'ps5', '["GTA 6","FC 26","Tekken 8"]', 3),
  ('M4', 'ps5', '["GTA 6","FC 26","Tekken 8"]', 4),
  ('M5', 'ps5', '["FC 26","Tekken 8"]', 5)
on conflict (id) do nothing;

-- =====================================================================
-- STILL TO DO (not in this file)
--   * Storage bucket 'payment-proofs': customers may upload, only owners may read.
--   * Limit on how many pending bookings one phone number can hold, to stop spam.
--   * Cancellation by the customer (12-hour rule) and credit.
--   * Walk-in and manual bookings from the staff screen.
--   * Starting a session from a booking (fills session_id, machine_id).
-- =====================================================================
