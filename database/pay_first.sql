-- =====================================================================
-- 404 Gaming Zone — pay first
-- Run AFTER link_sessions_bookings.sql. Safe to run twice.
--
-- Every payment taken at the counter is one line here: the start of a
-- session, each added hour, each added player, each snack, any balance.
-- A refund is a line with minus amounts, and only an owner can write one.
-- Lines are never edited or deleted, so this is also the audit trail.
-- =====================================================================
create table if not exists gz_session_payments (
  id         bigserial primary key,
  session_id text not null,
  kind       text not null default 'start' check (kind in ('start','time','player','snacks','balance','refund')),
  cash       numeric not null default 0,
  online     numeric not null default 0,
  staff      text,
  user_id    uuid not null default auth.uid() references auth.users,
  created_at timestamptz not null default now()
);
create index if not exists gz_session_payments_session_idx on gz_session_payments (session_id);
create index if not exists gz_session_payments_at_idx on gz_session_payments (created_at desc);

alter table gz_session_payments enable row level security;
drop policy if exists "session_pay_read"   on gz_session_payments;
drop policy if exists "session_pay_insert" on gz_session_payments;
create policy "session_pay_read" on gz_session_payments for select using (auth.uid() is not null);
-- Staff can only record money coming IN. Money going back needs an owner.
create policy "session_pay_insert" on gz_session_payments for insert with check (
  auth.uid() is not null and user_id = auth.uid()
  and ( (cash >= 0 and online >= 0 and kind <> 'refund') or is_owner() )
);
-- no update or delete policy: a payment line can never be changed or removed.
revoke all on gz_session_payments from anon;

do $$ begin
  alter publication supabase_realtime add table gz_session_payments;
exception when duplicate_object then null; when others then null; end $$;

select 'gz_session_payments' as "check", count(*)::text as installed from information_schema.tables where table_name = 'gz_session_payments'
union all select 'policies', count(*)::text from pg_policies where tablename = 'gz_session_payments';
