-- =====================================================================
-- Late entries — recording a snack sale that was missed at the time
--
-- Supabase -> SQL Editor -> New query -> paste all -> Run.
-- Safe to run more than once. Adds two columns and one guard. Nothing is
-- deleted, no existing rule changes, no existing row is touched.
--
-- Why this exists: staff sometimes serve a customer and forget to ring it
-- up. Without a way to enter it late, that sale is simply gone and the
-- drawer is over by its value. With a way to enter it late, the sale is
-- recovered — but a late entry is also the one obvious way to paper over a
-- shortage after the fact. So every late entry is labelled and attributed.
-- =====================================================================

-- created_at stays "when the sale actually happened", because that is what
-- every report already buckets by. entered_at records when it was typed in.
-- For an ordinary sale the two are the same. For a late entry they differ,
-- and that gap is the thing worth being able to see.
alter table sales add column if not exists entered_at timestamptz default now();
alter table sales add column if not exists backdated  boolean not null default false;

create index if not exists sales_backdated_idx on sales (backdated) where backdated = true;

-- Existing rows were all entered at the time, so they are not late entries.
update sales set entered_at = created_at where entered_at is null;

-- ---------------------------------------------------------------- GUARD
-- The client already limits what each role can pick, but a rule that only
-- lives in the client is a rule that can be got around. This enforces the
-- same limit in the database, where it actually holds:
--
--   owner  — may enter any past date
--   staff  — may only enter a late sale inside the current business day
--            (4am to 4am), so tonight's miss can be fixed tonight, but a
--            night that has already been counted and closed cannot be
--            quietly added to
--
-- Ordinary sales are deliberately NOT restricted by the business-day rule.
-- A phone that is offline overnight pushes its queue the next day, and that
-- sale is genuine, not a late entry. The 7-day floor below still applies to
-- it, which is far outside any real offline window.
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
  if auth.uid() is null then return new; end if;   -- service role / migrations
  if is_owner() then return new; end if;           -- owners may enter any date

  -- Voiding a sale is an UPDATE that touches only the void columns. It must
  -- keep working on an old row, so a date this trigger is not being asked to
  -- change is a date it has no business re-judging.
  --
  -- Nested deliberately rather than written as one AND chain: on an INSERT
  -- there is no OLD record, and plpgsql evaluates a condition as a single SQL
  -- expression, so mentioning old.created_at in the same line would risk
  -- "record old is not assigned yet" and block every sale in the shop.
  if TG_OP = 'UPDATE' then
    if new.created_at is not distinct from old.created_at
       and new.backdated is not distinct from old.backdated then
      return new;
    end if;
  end if;

  -- Nothing may be dated in the future, by anyone. A future-dated sale would
  -- sit outside every report until its date arrived.
  if new.created_at > now() + interval '5 minutes' then
    raise exception 'a sale cannot be dated in the future';
  end if;

  -- Crude floor for every staff insert, late entry or not.
  if new.created_at < now() - interval '7 days' then
    raise exception 'that date is too far back — ask an owner to enter it';
  end if;

  if coalesce(new.backdated, false) then
    -- Start of the current business day: 4am today, or 4am yesterday if it
    -- is currently between midnight and 4am. Worked out in Lahore time, not
    -- the server's UTC, or the cut-off would land at 9am local.
    local_now := now() at time zone 'Asia/Karachi';
    day_start := date_trunc('day', local_now) + interval '4 hours';
    if local_now < day_start then
      day_start := day_start - interval '1 day';
    end if;

    if (new.created_at at time zone 'Asia/Karachi') < day_start then
      raise exception 'staff can only add a missed sale from tonight — ask an owner for an earlier date';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists sales_backdate_guard_trg on sales;
create trigger sales_backdate_guard_trg
  before insert or update on sales
  for each row execute function sales_backdate_guard();

-- If this guard ever misbehaves, one line puts the database back exactly as
-- it was — the columns are harmless on their own:
--
--   drop trigger sales_backdate_guard_trg on sales;
--
-- ---------------------------------------------------------------- CHECK
select 'sales rows'                as check, count(*)::text as value from sales
union all
select 'late entries so far',      count(*)::text from sales where backdated
union all
select 'entered_at still empty (must be 0)', count(*)::text from sales where entered_at is null
union all
select 'guard installed (must be 1)', count(*)::text from pg_trigger
 where tgname = 'sales_backdate_guard_trg';

select column_name, data_type, column_default
  from information_schema.columns
 where table_name = 'sales' and column_name in ('entered_at','backdated')
 order by column_name;
