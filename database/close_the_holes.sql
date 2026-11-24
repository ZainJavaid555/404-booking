-- =====================================================================
-- Four ways cash could leave 404 without leaving a trace
--
-- Supabase -> SQL Editor -> New query -> paste all -> Run.
-- Safe to run more than once. Adds guards only; no data is changed and no
-- existing row is touched.
--
-- Each of these was demonstrated against the live database by impersonating
-- the real Staff account inside a rolled-back transaction. They are not
-- theoretical. None of them requires anything more than the shop phone and
-- a browser console.
--
--   1. Rewrite the amount of your own sale for 18 hours, leaving no VOID
--      tag, no voided_by, and nothing in the Voided counter.
--   2. Delete a live gaming session outright, so it never reaches history.
--   3. Move any item's stock by any amount, with no sale behind it.
--   4. Insert a sale into an already-counted night without the LATE label,
--      simply by not setting the backdated flag.
--
-- The gaming side was already right: gz_history is owner-only for UPDATE and
-- has no DELETE policy at all. This brings the rest up to that standard.
-- =====================================================================


-- ---------------------------------------------------------------- 1. SALES
-- Postgres RLS cannot restrict an UPDATE to particular columns, so the
-- "sales_void" policy that was meant to allow voiding in fact allowed
-- rewriting total, lines and pay_method as well. A trigger can do what the
-- policy cannot: let a non-owner change only the four void columns.
create or replace function sales_guard_amount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;   -- service role / migrations
  if is_owner() then return new; end if;

  if new.total       is distinct from old.total
     or new.cost_total is distinct from old.cost_total
     or new.profit     is distinct from old.profit
     or new.lines      is distinct from old.lines
     or new.pay_method is distinct from old.pay_method
     or new.created_at is distinct from old.created_at
     or new.staff      is distinct from old.staff
     or new.gz_session_id is distinct from old.gz_session_id
     or new.backdated  is distinct from old.backdated then
    raise exception 'a recorded sale cannot be altered — void it instead';
  end if;

  return new;
end;
$$;

drop trigger if exists sales_guard_amount_trg on sales;
create trigger sales_guard_amount_trg
  before update on sales
  for each row execute function sales_guard_amount();


-- ------------------------------------------------------- 2. LIVE SESSIONS
-- "gz_sessions_all" is FOR ALL, which includes DELETE, so a session could be
-- removed before it ever became a history row — the money simply never
-- existed. DELETE cannot just be revoked, because the app legitimately
-- deletes rows in two places: inside gz_end_session, and when tidying up a
-- session another device has already ended.
--
-- Both of those happen only AFTER the history row exists. That is the
-- difference this trigger keys on: you may delete a session that has been
-- archived, and not one that has not.
create or replace function gz_sessions_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return old; end if;
  if is_owner() then return old; end if;

  if not exists (select 1 from gz_history where id = old.id) then
    raise exception 'end the session instead — deleting it would erase the money';
  end if;

  return old;
end;
$$;

drop trigger if exists gz_sessions_guard_delete_trg on gz_sessions;
create trigger gz_sessions_guard_delete_trg
  before delete on gz_sessions
  for each row execute function gz_sessions_guard_delete();


-- ----------------------------------------------------------- 3. STOCK
-- adjust_stock is SECURITY DEFINER and granted to every signed-in user with
-- no bound and no record of who called it. Ten units can be taken off the
-- shelf and the count quietly corrected, which removes the only signal an
-- owner has left: stock that does not reconcile with sales.
--
-- The fix is not to block staff — the till has to move stock on every sale —
-- but to bound it and write down who did it.
create table if not exists stock_log (
  id         bigserial primary key,
  item_id    text,
  delta      numeric,
  by_uid     uuid,
  at         timestamptz default now()
);
alter table stock_log enable row level security;
drop policy if exists "stock_log_owner_read" on stock_log;
create policy "stock_log_owner_read" on stock_log for select using (is_owner());
-- No insert policy: rows are written only by adjust_stock, which is definer.

create index if not exists stock_log_at_idx on stock_log (at desc);

-- Returns numeric to match the function already deployed — Postgres will not
-- let CREATE OR REPLACE change a return type, and dropping it first would
-- briefly leave the till unable to move stock.
create or replace function adjust_stock(p_id text, p_delta numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  new_stock numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  -- A single sale is a handful of units. Anything past 500 is a mistake or
  -- someone poking at the API; owners are not bounded, for stocktakes.
  if not is_owner() and abs(coalesce(p_delta,0)) > 500 then
    raise exception 'stock change too large — ask an owner';
  end if;

  update items
     set stock = greatest(0, stock + p_delta),
         updated_at = now()
   where id = p_id
   returning stock into new_stock;

  insert into stock_log (item_id, delta, by_uid) values (p_id, p_delta, auth.uid());
  return new_stock;
end;
$$;

revoke all on function adjust_stock(text, numeric) from public;
grant execute on function adjust_stock(text, numeric) to authenticated;


-- ------------------------------------------------- 4. THE BACKDATE FLAG
-- The late-entry guard only ran when the client volunteered backdated=true,
-- so omitting one boolean put an unlabelled sale into a night that had
-- already been counted.
--
-- Rejecting every old insert is not an option: a phone that was offline
-- overnight pushes genuine sales the next day, and those must not be lost.
-- So instead of refusing the row, this LABELS it. A sale dated before the
-- current business day is marked backdated whether the client said so or
-- not, which means it can still arrive — it just cannot arrive invisibly.
create or replace function sales_backdate_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  local_now timestamp;
  day_start timestamp;
begin
  if auth.uid() is null then return new; end if;
  if is_owner() then return new; end if;

  if TG_OP = 'UPDATE' then
    if new.created_at is not distinct from old.created_at
       and new.backdated is not distinct from old.backdated then
      return new;
    end if;
  end if;

  if new.created_at > now() + interval '5 minutes' then
    raise exception 'a sale cannot be dated in the future';
  end if;

  if new.created_at < now() - interval '7 days' then
    raise exception 'that date is too far back — ask an owner to enter it';
  end if;

  -- Start of the current business day, in Lahore time: 4am today, or 4am
  -- yesterday if it is currently between midnight and 4am.
  local_now := now() at time zone 'Asia/Karachi';
  day_start := date_trunc('day', local_now) + interval '4 hours';
  if local_now < day_start then day_start := day_start - interval '1 day'; end if;

  -- Anything dated before tonight is a late entry by definition. Set the
  -- flag here rather than trusting the client to admit it.
  if (new.created_at at time zone 'Asia/Karachi') < day_start then
    new.backdated := true;
    if new.entered_at is null then new.entered_at := now(); end if;
  end if;

  return new;
end;
$$;

drop trigger if exists sales_backdate_guard_trg on sales;
create trigger sales_backdate_guard_trg
  before insert or update on sales
  for each row execute function sales_backdate_guard();


-- ---------------------------------------------------------------- ROLLBACK
-- Any of these can be lifted individually if it gets in the way:
--   drop trigger sales_guard_amount_trg on sales;
--   drop trigger gz_sessions_guard_delete_trg on gz_sessions;
--   drop trigger sales_backdate_guard_trg on sales;

-- ---------------------------------------------------------------- CHECK
select 'sales amount guard'      as check, count(*)::text as installed from pg_trigger where tgname='sales_guard_amount_trg'
union all select 'session delete guard', count(*)::text from pg_trigger where tgname='gz_sessions_guard_delete_trg'
union all select 'backdate guard',       count(*)::text from pg_trigger where tgname='sales_backdate_guard_trg'
union all select 'stock_log table',      count(*)::text from information_schema.tables where table_name='stock_log'
union all select 'gz_history rows (unchanged)', count(*)::text from gz_history
union all select 'sales rows (unchanged)',      count(*)::text from sales;
