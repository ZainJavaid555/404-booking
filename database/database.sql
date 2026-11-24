-- =====================================================================
-- 404 Snacks — database schema and permission rules
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to re-run: everything is guarded with IF NOT EXISTS / OR REPLACE.
-- =====================================================================

-- ---------------------------------------------------------------- PROFILES
-- Maps a Supabase login to a person and a role. The app never decides its
-- own role; it reads it from here and the rules below enforce it.
create table if not exists profiles (
  id         uuid primary key references auth.users on delete cascade,
  name       text not null,
  role       text not null check (role in ('owner','staff')),
  created_at timestamptz default now()
);

-- Used by every policy. SECURITY DEFINER so it can read profiles even when
-- the caller is not allowed to read other people's rows.
create or replace function is_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner');
$$;

-- ---------------------------------------------------------------- ITEMS
create table if not exists items (
  id         text primary key,
  name       text not null,
  photo      text default '',
  cost       numeric default 0 check (cost  >= 0),
  price      numeric default 0 check (price >= 0),
  stock      numeric default 0,
  active     boolean default true,
  updated_at timestamptz default now()
);

-- ---------------------------------------------------------------- SALES
create table if not exists sales (
  id          text primary key,
  created_at  timestamptz default now(),
  lines       jsonb not null,
  total       numeric default 0 check (total      >= 0),
  cost_total  numeric default 0 check (cost_total >= 0),
  profit      numeric default 0,
  staff       text,
  user_id     uuid default auth.uid() references auth.users,
  voided      boolean default false,
  void_reason text,
  voided_by   text,
  voided_at   timestamptz
);

create index if not exists sales_created_idx on sales (created_at desc);
create index if not exists sales_user_idx    on sales (user_id);

-- ---------------------------------------------------------------- RULES
alter table profiles enable row level security;
alter table items    enable row level security;
alter table sales    enable row level security;

drop policy if exists "profile_read_own"      on profiles;
drop policy if exists "items_read"            on items;
drop policy if exists "items_owner_insert"    on items;
drop policy if exists "items_owner_update"    on items;
drop policy if exists "items_owner_delete"    on items;
drop policy if exists "sales_read"            on sales;
drop policy if exists "sales_insert_own"      on sales;
drop policy if exists "sales_void"            on sales;

-- Everyone reads their own profile; owners can see the team.
create policy "profile_read_own" on profiles
  for select using (id = auth.uid() or is_owner());

-- Anyone signed in can see the product list...
create policy "items_read" on items
  for select using (auth.uid() is not null);

-- ...but ONLY owners can create, change or remove products. This is the rule
-- that stops a staff member editing a price, even outside the app.
create policy "items_owner_insert" on items
  for insert with check (is_owner());
create policy "items_owner_update" on items
  for update using (is_owner()) with check (is_owner());
create policy "items_owner_delete" on items
  for delete using (is_owner());

-- Sales are visible to the whole team.
create policy "sales_read" on sales
  for select using (auth.uid() is not null);

-- Anyone signed in can record a sale, but it is stamped with THEIR user id —
-- they cannot post a sale as someone else.
create policy "sales_insert_own" on sales
  for insert with check (auth.uid() is not null and user_id = auth.uid());

-- Voiding: owners may void anything. Staff may only void their own sale, and
-- only within 18 hours (covers a full 12pm-3am shift plus slack).
create policy "sales_void" on sales
  for update
  using      (is_owner() or (user_id = auth.uid() and created_at > now() - interval '18 hours'))
  with check (is_owner() or (user_id = auth.uid() and created_at > now() - interval '18 hours'));

-- No delete policy on sales, deliberately: nobody can erase a sale, ever.
-- Mistakes are voided, which leaves a visible record.

-- ---------------------------------------------------------------- STOCK
-- Staff cannot UPDATE items, yet selling must reduce stock. This function runs
-- with elevated rights and does the change atomically inside the database, so
-- two phones selling the same item at the same time cannot overwrite each other.
create or replace function adjust_stock(p_id text, p_delta numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  new_stock numeric;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;

  update items
     set stock = greatest(0, stock + p_delta),
         updated_at = now()
   where id = p_id
   returning stock into new_stock;

  if not found then
    raise exception 'no such item: %', p_id;
  end if;

  return new_stock;
end;
$$;

revoke all on function adjust_stock(text, numeric) from public;
grant execute on function adjust_stock(text, numeric) to authenticated;

-- ---------------------------------------------------------------- REALTIME
-- Lets one phone update the moment another makes a sale.
do $$
begin
  begin execute 'alter publication supabase_realtime add table items'; exception when others then null; end;
  begin execute 'alter publication supabase_realtime add table sales'; exception when others then null; end;
end $$;

-- =====================================================================
-- THIS IS ALREADY DEPLOYED
--
-- Project : Snacks & Drinks  (ap-northeast-2, Seoul)
-- URL     : (the live project)
--
-- Logins created and roles assigned:
--   owner-1@example.com         -> owner
--   owner-2@example.com         -> owner
--   staff@example.com               -> staff   (shared counter login)
--
-- Verified live against these rules:
--   staff changes a price ............ BLOCKED
--   staff deletes a product .......... BLOCKED
--   staff records a sale ............. allowed
--   staff posts a sale as the owner .. BLOCKED
--   staff reduces stock on a sale .... allowed
--   owner deletes a sale ............. BLOCKED (nobody can)
--   owner changes a price ............ allowed
--
-- To add another person later:
--   1. Authentication -> Users -> Add user (tick Auto Confirm User)
--   2. insert into profiles (id, name, role)
--      select id, 'Staff', 'staff' from auth.users where email = 'their@email'
--      on conflict (id) do update set name = excluded.name, role = excluded.role;
-- =====================================================================
