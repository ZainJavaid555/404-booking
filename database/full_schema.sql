-- 404 Gaming Zone: full database structure (public schema). Structure only, NO row data.
-- Exported read-only from the live Supabase project on 24 Nov 2026.
-- For building a TEST database. Do not run this against the live project.
-- Before running: create sequence if not exists stock_log_id_seq;

create table gz_history (
  id text not null,
  platform text,
  game text default ''::text,
  player_count integer default 0,
  player_names jsonb not null default '[]'::jsonb,
  start_time bigint not null,
  end_time bigint not null,
  paid_hours integer not null default 1,
  hourly_rate numeric not null default 0,
  price_segments jsonb not null default '[]'::jsonb,
  revenue numeric not null default 0,
  ended_by text,
  voided boolean not null default false,
  void_reason text,
  voided_by text,
  voided_at timestamp with time zone,
  created_at timestamp with time zone default now(),
  pay_method text,
  edits jsonb not null default '[]'::jsonb,
  cash_amount numeric,
  online_amount numeric
);

create table gz_players (
  key text not null,
  name text not null,
  phone text,
  visits integer not null default 0,
  first_visit bigint,
  last_visit bigint,
  updated_at timestamp with time zone default now()
);

create table gz_sessions (
  id text not null,
  platform text not null,
  game text default ''::text,
  players jsonb not null default '[]'::jsonb,
  start_time bigint not null,
  end_time bigint not null,
  total_ms bigint not null,
  paid_hours integer not null default 1,
  hourly_rate numeric not null default 0,
  price_segments jsonb not null default '[]'::jsonb,
  started_by text,
  updated_at timestamp with time zone default now()
);

create table gz_settings (
  id text not null default 'main'::text,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamp with time zone default now(),
  updated_by text
);

create table items (
  id text not null,
  name text not null,
  photo text default ''::text,
  cost numeric default 0,
  price numeric default 0,
  stock numeric default 0,
  active boolean default true,
  updated_at timestamp with time zone default now()
);

create table profiles (
  id uuid not null,
  name text not null,
  role text not null,
  created_at timestamp with time zone default now()
);

create table sales (
  id text not null,
  created_at timestamp with time zone default now(),
  lines jsonb not null,
  total numeric default 0,
  cost_total numeric default 0,
  profit numeric default 0,
  staff text,
  user_id uuid default auth.uid(),
  voided boolean default false,
  void_reason text,
  voided_by text,
  voided_at timestamp with time zone,
  pay_method text,
  gz_session_id text,
  settled_at timestamp with time zone,
  entered_at timestamp with time zone default now(),
  backdated boolean not null default false,
  cash_amount numeric,
  online_amount numeric
);

create table stock_log (
  id bigint not null default nextval('stock_log_id_seq'::regclass),
  item_id text,
  delta numeric,
  by_uid uuid,
  at timestamp with time zone default now(),
  unit_cost numeric,
  kind text,
  note text
);

alter table gz_history add constraint gz_history_pay_method_chk CHECK (((pay_method IS NULL) OR (pay_method = ANY (ARRAY['cash'::text, 'online'::text, 'split'::text]))));

alter table gz_history add constraint gz_history_pkey PRIMARY KEY (id);

alter table gz_history add constraint gz_history_revenue_check CHECK ((revenue >= (0)::numeric));

alter table gz_players add constraint gz_players_pkey PRIMARY KEY (key);

alter table gz_sessions add constraint gz_sessions_pkey PRIMARY KEY (id);

alter table gz_settings add constraint gz_settings_pkey PRIMARY KEY (id);

alter table items add constraint items_cost_check CHECK ((cost >= (0)::numeric));

alter table items add constraint items_pkey PRIMARY KEY (id);

alter table items add constraint items_price_check CHECK ((price >= (0)::numeric));

alter table profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table profiles add constraint profiles_pkey PRIMARY KEY (id);

alter table profiles add constraint profiles_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'staff'::text])));

alter table sales add constraint sales_cost_total_check CHECK ((cost_total >= (0)::numeric));

alter table sales add constraint sales_pay_method_chk CHECK (((pay_method IS NULL) OR (pay_method = ANY (ARRAY['cash'::text, 'online'::text, 'split'::text]))));

alter table sales add constraint sales_pkey PRIMARY KEY (id);

alter table sales add constraint sales_total_check CHECK ((total >= (0)::numeric));

alter table sales add constraint sales_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);

alter table stock_log add constraint stock_log_pkey PRIMARY KEY (id);

CREATE INDEX gz_history_live_idx ON public.gz_history USING btree (voided, start_time DESC);

CREATE INDEX gz_history_pay_idx ON public.gz_history USING btree (pay_method);

CREATE INDEX gz_history_start_idx ON public.gz_history USING btree (start_time DESC);

CREATE INDEX sales_backdated_idx ON public.sales USING btree (backdated) WHERE (backdated = true);

CREATE INDEX sales_created_idx ON public.sales USING btree (created_at DESC);

CREATE INDEX sales_open_tab_idx ON public.sales USING btree (gz_session_id) WHERE (settled_at IS NULL);

CREATE INDEX sales_pay_idx ON public.sales USING btree (pay_method);

CREATE INDEX sales_session_idx ON public.sales USING btree (gz_session_id);

CREATE INDEX sales_user_idx ON public.sales USING btree (user_id);

CREATE INDEX stock_log_at_idx ON public.stock_log USING btree (at DESC);

CREATE INDEX stock_log_item_idx ON public.stock_log USING btree (item_id, at DESC);

CREATE INDEX stock_log_kind_idx ON public.stock_log USING btree (kind, at DESC);

alter table gz_history enable row level security;

alter table gz_players enable row level security;

alter table gz_sessions enable row level security;

alter table gz_settings enable row level security;

alter table items enable row level security;

alter table profiles enable row level security;

alter table sales enable row level security;

alter table stock_log enable row level security;

CREATE OR REPLACE FUNCTION public.adjust_stock(p_id text, p_delta numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_stock numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  if not is_owner() and abs(coalesce(p_delta,0)) > 500 then
    raise exception 'stock change too large — ask an owner';
  end if;

  update items
     set stock = greatest(0, stock + p_delta),
         updated_at = now()
   where id = p_id
   returning stock into new_stock;

  insert into stock_log (item_id, delta, by_uid, kind)
  values (p_id, p_delta, auth.uid(),
          case when p_delta > 0 then 'return' else 'sale' end);

  return new_stock;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_delivery(p_log_id bigint, p_reverse boolean)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  row_item  text;
  row_delta numeric;
  row_kind  text;
  new_stock numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can remove a delivery'; end if;

  select item_id, delta, kind into row_item, row_delta, row_kind
    from stock_log where id = p_log_id;
  if row_item is null then raise exception 'that entry is no longer there'; end if;
  if row_kind <> 'purchase' then
    raise exception 'only a delivery can be removed';
  end if;

  if coalesce(p_reverse, false) then
    update items
       set stock = greatest(0, stock - row_delta), updated_at = now()
     where id = row_item
     returning stock into new_stock;
    -- The reversal is a movement in its own right. Written down as a count
    -- correction so the history of the shelf stays continuous — a delivery
    -- that vanishes without its units leaving a trace would make every
    -- "stock on that date" before it wrong.
    insert into stock_log (item_id, delta, by_uid, kind, note)
    values (row_item, -row_delta, auth.uid(), 'count', 'delivery removed');
  else
    select stock into new_stock from items where id = row_item;
  end if;

  delete from stock_log where id = p_log_id;
  return coalesce(new_stock, 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_item_history(p_item_id text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can do this'; end if;

  delete from stock_log where item_id = p_item_id;
  get diagnostics n = row_count;
  return n;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_add_to_tab(p_session_id text, p_lines jsonb, p_staff text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tab_id   text := 'tab_' || p_session_id;
  cur      jsonb;
  merged   jsonb;
  incoming jsonb;
  found    boolean;
  i        int;
  new_tot  numeric := 0;
  new_cost numeric := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  -- the open tab for this session, if there is one
  select lines into cur from sales
   where id = tab_id and settled_at is null and coalesce(voided,false) = false;

  if cur is null then
    cur := '[]'::jsonb;
  end if;

  -- fold each incoming line into what is already there
  for incoming in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb))
  loop
    found := false;
    merged := '[]'::jsonb;
    for i in 0 .. coalesce(jsonb_array_length(cur),1) - 1 loop
      if (cur->i->>'id') = (incoming->>'id') then
        merged := merged || jsonb_build_array(
          jsonb_set(cur->i, '{qty}',
            to_jsonb( coalesce((cur->i->>'qty')::numeric,0) + coalesce((incoming->>'qty')::numeric,0) )));
        found := true;
      else
        merged := merged || jsonb_build_array(cur->i);
      end if;
    end loop;
    if not found then merged := merged || jsonb_build_array(incoming); end if;
    cur := merged;
  end loop;

  -- recompute the money from the merged lines
  for i in 0 .. coalesce(jsonb_array_length(cur),1) - 1 loop
    new_tot  := new_tot  + coalesce((cur->i->>'qty')::numeric,0) * coalesce((cur->i->>'price')::numeric,0);
    new_cost := new_cost + coalesce((cur->i->>'qty')::numeric,0) * coalesce((cur->i->>'cost')::numeric,0);
  end loop;

  insert into sales (id, created_at, lines, total, cost_total, profit, staff,
                     user_id, gz_session_id, settled_at, voided)
  values (tab_id, now(), cur, new_tot, new_cost, new_tot - new_cost, p_staff,
          auth.uid(), p_session_id, null, false)
  on conflict (id) do update
     set lines = excluded.lines,
         total = excluded.total,
         cost_total = excluded.cost_total,
         profit = excluded.profit,
         staff = excluded.staff;

  return jsonb_build_object('id', tab_id, 'total', new_tot, 'lines', cur);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_end_session(p_id text, p_record jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  method text    := nullif(p_record->>'pay_method','');
  cash   numeric := nullif(p_record->>'cash_amount','')::numeric;
  onl    numeric := nullif(p_record->>'online_amount','')::numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  insert into gz_history (
    id, platform, game, player_count, player_names,
    start_time, end_time, paid_hours, hourly_rate,
    price_segments, revenue, ended_by, pay_method,
    cash_amount, online_amount
  ) values (
    p_record->>'id',
    p_record->>'platform',
    coalesce(p_record->>'game',''),
    coalesce((p_record->>'player_count')::int, 0),
    coalesce(p_record->'player_names', '[]'::jsonb),
    (p_record->>'start_time')::bigint,
    (p_record->>'end_time')::bigint,
    coalesce((p_record->>'paid_hours')::int, 1),
    coalesce((p_record->>'hourly_rate')::numeric, 0),
    coalesce(p_record->'price_segments', '[]'::jsonb),
    coalesce((p_record->>'revenue')::numeric, 0),
    p_record->>'ended_by',
    method,
    -- The WHOLE bill: the gaming plus whatever was on the customer's snack
    -- tab, because that is what they actually handed over. This is normally
    -- more than `revenue`, which holds the gaming part alone.
    cash, onl
  )
  on conflict (id) do nothing;

  -- Settle the snack tab for this session. The rows take the session's LABEL
  -- so the till can show how the customer paid, but deliberately no amounts:
  -- the session row above already holds the whole bill, and giving the tab
  -- rows amounts as well would count the same money twice in every total.
  update sales
     set pay_method = coalesce(pay_method, method),
         settled_at = now()
   where gz_session_id = p_id
     and settled_at is null
     and coalesce(voided,false) = false;

  delete from gz_sessions where id = p_id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_session_tabs()
 RETURNS TABLE(session_id text, items bigint, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select gz_session_id, count(*)::bigint, coalesce(sum(total),0)
    from sales
   where gz_session_id is not null
     and settled_at is null
     and coalesce(voided,false) = false
   group by gz_session_id;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_sessions_guard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return old; end if;
  if is_owner() then return old; end if;

  if not exists (select 1 from gz_history where id = old.id) then
    raise exception 'end the session instead — deleting it would erase the money';
  end if;

  return old;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_set_payment(p_sale_id text, p_session_id text, p_pay text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare amt numeric;
begin
  if p_pay is null then
    return gz_set_payment_split(p_sale_id, p_session_id, 0, 0);
  end if;
  if p_pay not in ('cash','online') then
    raise exception 'payment must be cash, online, or nothing';
  end if;

  if p_sale_id is not null then
    select total into amt from sales where id = p_sale_id;
  else
    -- The whole bill, not just the gaming: the customer settled their snack
    -- tab with the same payment. Taking revenue alone here would record less
    -- money than actually changed hands.
    select coalesce(h.revenue,0)
         + coalesce((select sum(s.total) from sales s
                      where s.gz_session_id = h.id and s.voided = false), 0)
      into amt
      from gz_history h where h.id = p_session_id;
  end if;
  amt := coalesce(amt, 0);

  if p_pay = 'cash' then
    return gz_set_payment_split(p_sale_id, p_session_id, amt, 0);
  else
    return gz_set_payment_split(p_sale_id, p_session_id, 0, amt);
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_set_payment_split(p_sale_id text, p_session_id text, p_cash numeric, p_online numeric)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n     integer := 0;
  cash  numeric := round(coalesce(p_cash,0));
  onl   numeric := round(coalesce(p_online,0));
  label text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then
    raise exception 'only an owner can change how a bill was paid';
  end if;
  if cash < 0 or onl < 0 then raise exception 'an amount cannot be negative'; end if;

  -- The label is derived, never supplied. Nothing recorded means nothing
  -- recorded; one side only is the simple case; both is a split.
  label := case when cash = 0 and onl = 0 then null
                when onl  = 0 then 'cash'
                when cash = 0 then 'online'
                else 'split' end;

  if p_sale_id is not null then
    update sales
       set pay_method = label, cash_amount = cash, online_amount = onl
     where id = p_sale_id and voided = false;
    get diagnostics n = row_count;
    return n;
  end if;

  if p_session_id is not null then
    update gz_history
       set pay_method = label, cash_amount = cash, online_amount = onl
     where id = p_session_id and voided = false;
    get diagnostics n = row_count;

    -- The snacks on that customer's tab were settled with the same bill, so
    -- they carry the same label. Their AMOUNTS stay null on purpose: the
    -- session row already holds the whole bill, and giving the tab rows
    -- amounts too would count the same money twice in the day's totals.
    update sales
       set pay_method = label, cash_amount = null, online_amount = null
     where gz_session_id = p_session_id and voided = false;
    return n;
  end if;

  return 0;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_set_tab_lines(p_session_id text, p_lines jsonb, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tab_id  text := 'tab_' || p_session_id;
  old     jsonb;
  i       int;
  item_id text;
  old_q   numeric;
  new_q   numeric;
  tot     numeric := 0;
  cst     numeric := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  select lines into old from sales
   where id = tab_id and settled_at is null and coalesce(voided,false) = false;
  if not found then raise exception 'that tab is closed or does not exist'; end if;
  old := coalesce(old, '[]'::jsonb);

  -- put back / take out the difference for every item mentioned either side
  for item_id in
    select distinct x from (
      select jsonb_array_elements(old)->>'id' as x
      union
      select jsonb_array_elements(coalesce(p_lines,'[]'::jsonb))->>'id'
    ) q where x is not null
  loop
    select coalesce(sum((e->>'qty')::numeric),0) into old_q
      from jsonb_array_elements(old) e where e->>'id' = item_id;
    select coalesce(sum((e->>'qty')::numeric),0) into new_q
      from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e where e->>'id' = item_id;
    if old_q <> new_q then
      update items set stock = greatest(0, stock + (old_q - new_q)), updated_at = now()
       where id = item_id;
    end if;
  end loop;

  for i in 0 .. coalesce(jsonb_array_length(coalesce(p_lines,'[]'::jsonb)),1) - 1 loop
    tot := tot + coalesce((p_lines->i->>'qty')::numeric,0) * coalesce((p_lines->i->>'price')::numeric,0);
    cst := cst + coalesce((p_lines->i->>'qty')::numeric,0) * coalesce((p_lines->i->>'cost')::numeric,0);
  end loop;

  if coalesce(jsonb_array_length(coalesce(p_lines,'[]'::jsonb)),0) = 0 then
    -- nothing left on the tab: void it rather than leave an empty sale
    update sales set voided = true, void_reason = 'All items removed',
                     voided_by = p_by, voided_at = now()
     where id = tab_id;
    return jsonb_build_object('emptied', true, 'total', 0);
  end if;

  update sales
     set lines = p_lines, total = tot, cost_total = cst, profit = tot - cst
   where id = tab_id;

  return jsonb_build_object('emptied', false, 'total', tot);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_snacks_by_session()
 RETURNS TABLE(session_id text, items bigint, amount numeric, open_items bigint, open_amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select gz_session_id,
         count(*)::bigint,
         coalesce(sum(total),0),
         count(*) filter (where settled_at is null)::bigint,
         coalesce(sum(total) filter (where settled_at is null),0)
    from sales
   where gz_session_id is not null
     and coalesce(voided,false) = false
   group by gz_session_id;
$function$
;

CREATE OR REPLACE FUNCTION public.gz_void_session(p_id text, p_reason text, p_by text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  row_start bigint;
  sale      record;
  line      jsonb;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'a reason is required'; end if;

  select start_time into row_start from gz_history where id = p_id and voided = false;
  if not found then return false; end if;

  if not is_owner() and row_start < (extract(epoch from now()) * 1000) - (18 * 3600 * 1000) then
    raise exception 'too old to void - ask an owner';
  end if;

  update gz_history
     set voided = true, void_reason = p_reason, voided_by = p_by, voided_at = now()
   where id = p_id and voided = false;

  -- the snacks that were on this session's tab
  for sale in
    select id, lines from sales
     where gz_session_id = p_id and coalesce(voided,false) = false
  loop
    update sales
       set voided = true,
           void_reason = 'Session voided: ' || p_reason,
           voided_by = p_by,
           voided_at = now()
     where id = sale.id;

    -- put every packet back on the shelf
    for line in select * from jsonb_array_elements(coalesce(sale.lines, '[]'::jsonb))
    loop
      update items
         set stock = stock + coalesce((line->>'qty')::numeric, 0),
             updated_at = now()
       where id = line->>'id';
    end loop;
  end loop;

  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner');
$function$
;

CREATE OR REPLACE FUNCTION public.record_count(p_id text, p_counted numeric, p_note text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  before_qty numeric;
  diff       numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can correct a count'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'enter what you counted'; end if;

  select stock into before_qty from items where id = p_id;
  if before_qty is null then raise exception 'no such item'; end if;

  diff := p_counted - before_qty;
  if diff = 0 then return before_qty; end if;

  update items set stock = p_counted, updated_at = now() where id = p_id;

  insert into stock_log (item_id, delta, by_uid, kind, note)
  values (p_id, diff, auth.uid(), 'count', p_note);

  return p_counted;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_purchase(p_id text, p_qty numeric, p_unit_cost numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  new_stock numeric;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can add stock'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'how many did you buy?'; end if;
  if p_qty > 100000 then raise exception 'that quantity looks wrong'; end if;
  if coalesce(p_unit_cost,0) < 0 then raise exception 'a price cannot be negative'; end if;

  update items
     set stock = stock + p_qty,
         -- Keep the item's cost current. Sales snapshot the cost at the moment
         -- they happen, so past profit figures are unaffected by this.
         cost = case when coalesce(p_unit_cost,0) > 0 then p_unit_cost else cost end,
         updated_at = now()
   where id = p_id
   returning stock into new_stock;

  if new_stock is null then raise exception 'no such item'; end if;

  insert into stock_log (item_id, delta, by_uid, unit_cost, kind)
  values (p_id, p_qty, auth.uid(), p_unit_cost, 'purchase');

  return new_stock;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_purchase_backdated(p_id text, p_qty numeric, p_unit_cost numeric, p_at timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  log_start timestamptz;
  new_id    bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only an owner can record a past delivery'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'how many arrived?'; end if;
  if p_qty > 100000 then raise exception 'that quantity looks wrong'; end if;
  if coalesce(p_unit_cost,0) <= 0 then raise exception 'what was paid for each one?'; end if;
  if p_at is null or p_at > now() then raise exception 'a delivery cannot be dated in the future'; end if;
  if not exists (select 1 from items where id = p_id) then raise exception 'no such item'; end if;

  -- Only for the time BEFORE the log began. Anything since has been logged
  -- as it happened; a "forgotten" delivery from that period should go in
  -- as a normal one, which moves the shelf, because it never did.
  -- Deliveries recorded after the fact are dated in the past on purpose;
  -- they must not be allowed to move "when the log began" earlier, or the
  -- second past delivery an owner enters would be refused by the first.
  select min(at) into log_start from stock_log
   where coalesce(note,'') <> 'recorded after the fact';
  if log_start is not null and p_at >= log_start then
    raise exception 'deliveries since % are recorded as they happen — use the normal form',
      to_char(log_start at time zone 'Asia/Karachi', 'DD Mon');
  end if;

  insert into stock_log (item_id, delta, by_uid, unit_cost, kind, note, at)
  values (p_id, p_qty, auth.uid(), p_unit_cost, 'purchase', 'recorded after the fact', p_at)
  returning id into new_id;

  return new_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sales_backdate_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.sales_guard_amount()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then return new; end if;   -- service role / migrations
  if is_owner() then return new; end if;

  -- ---- an OPEN TAB: a running bill attached to a live session ----------
  if old.gz_session_id is not null and old.settled_at is null then
    -- the things about a tab that must never move under staff hands
    if new.gz_session_id is distinct from old.gz_session_id
       or new.created_at    is distinct from old.created_at
       or new.backdated     is distinct from old.backdated then
      raise exception 'a tab cannot be moved or re-dated';
    end if;
    -- a tab can only grow. Taking items OFF a tab is an owner's correction.
    if coalesce(new.total, 0) < coalesce(old.total, 0) then
      raise exception 'items can only be added to a tab — ask an owner to remove one';
    end if;
    -- a tab is settled once. A payment already recorded cannot be changed here.
    if old.pay_method is not null and new.pay_method is distinct from old.pay_method then
      raise exception 'how this tab was paid has already been recorded';
    end if;
    return new;
  end if;

  -- ---- a RECORDED SALE: counter sale, or a tab that has been settled ----
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
$function$
;

create policy gz_history_insert on gz_history as PERMISSIVE for INSERT to public
  with check ((auth.uid() IS NOT NULL));

create policy gz_history_owner_up on gz_history as PERMISSIVE for UPDATE to public
  using (is_owner())
  with check (is_owner());

create policy gz_history_read on gz_history as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy gz_players_read on gz_players as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy gz_players_update on gz_players as PERMISSIVE for UPDATE to public
  using ((auth.uid() IS NOT NULL))
  with check ((auth.uid() IS NOT NULL));

create policy gz_players_write on gz_players as PERMISSIVE for INSERT to public
  with check ((auth.uid() IS NOT NULL));

create policy gz_sessions_all on gz_sessions as PERMISSIVE for ALL to public
  using ((auth.uid() IS NOT NULL))
  with check ((auth.uid() IS NOT NULL));

create policy gz_settings_owner on gz_settings as PERMISSIVE for UPDATE to public
  using (is_owner())
  with check (is_owner());

create policy gz_settings_owner_i on gz_settings as PERMISSIVE for INSERT to public
  with check (is_owner());

create policy gz_settings_read on gz_settings as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy items_owner_delete on items as PERMISSIVE for DELETE to public
  using (is_owner());

create policy items_owner_insert on items as PERMISSIVE for INSERT to public
  with check (is_owner());

create policy items_owner_update on items as PERMISSIVE for UPDATE to public
  using (is_owner())
  with check (is_owner());

create policy items_read on items as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy profile_read_own on profiles as PERMISSIVE for SELECT to public
  using (((id = auth.uid()) OR is_owner()));

create policy sales_insert_own on sales as PERMISSIVE for INSERT to public
  with check (((auth.uid() IS NOT NULL) AND (user_id = auth.uid())));

create policy sales_read on sales as PERMISSIVE for SELECT to public
  using ((auth.uid() IS NOT NULL));

create policy sales_void on sales as PERMISSIVE for UPDATE to public
  using ((is_owner() OR ((user_id = auth.uid()) AND (created_at > (now() - '18:00:00'::interval)))))
  with check ((is_owner() OR ((user_id = auth.uid()) AND (created_at > (now() - '18:00:00'::interval)))));

create policy stock_log_owner_read on stock_log as PERMISSIVE for SELECT to public
  using (is_owner());

CREATE TRIGGER gz_sessions_guard_delete_trg BEFORE DELETE ON public.gz_sessions FOR EACH ROW EXECUTE FUNCTION gz_sessions_guard_delete();

CREATE TRIGGER sales_backdate_guard_trg BEFORE INSERT OR UPDATE ON public.sales FOR EACH ROW EXECUTE FUNCTION sales_backdate_guard();

CREATE TRIGGER sales_guard_amount_trg BEFORE UPDATE ON public.sales FOR EACH ROW EXECUTE FUNCTION sales_guard_amount();

grant execute on function adjust_stock(text,numeric) to anon, authenticated, postgres, service_role;

grant execute on function delete_delivery(bigint,boolean) to anon, authenticated, postgres, service_role;

grant execute on function delete_item_history(text) to anon, authenticated, postgres, service_role;

grant execute on function gz_add_to_tab(text,jsonb,text) to anon, authenticated, postgres, service_role;

grant execute on function gz_end_session(text,jsonb) to anon, authenticated, postgres, service_role;

grant execute on function gz_session_tabs() to anon, authenticated, postgres, service_role;

grant execute on function gz_sessions_guard_delete() to anon, authenticated, postgres, service_role;

grant execute on function gz_set_payment(text,text,text) to anon, authenticated, postgres, service_role;

grant execute on function gz_set_payment_split(text,text,numeric,numeric) to anon, authenticated, postgres, service_role;

grant execute on function gz_set_tab_lines(text,jsonb,text) to anon, authenticated, postgres, service_role;

grant execute on function gz_snacks_by_session() to anon, authenticated, postgres, service_role;

grant execute on function gz_void_session(text,text,text) to anon, authenticated, postgres, service_role;

grant execute on function is_owner() to anon, authenticated, postgres, service_role;

grant execute on function record_count(text,numeric,text) to anon, authenticated, postgres, service_role;

grant execute on function record_purchase(text,numeric,numeric) to anon, authenticated, postgres, service_role;

grant execute on function record_purchase_backdated(text,numeric,numeric,timestamp with time zone) to anon, authenticated, postgres, service_role;

grant execute on function sales_backdate_guard() to anon, authenticated, postgres, service_role;

grant execute on function sales_guard_amount() to anon, authenticated, postgres, service_role;

alter publication supabase_realtime add table gz_history;

alter publication supabase_realtime add table gz_players;

alter publication supabase_realtime add table gz_sessions;

alter publication supabase_realtime add table gz_settings;

alter publication supabase_realtime add table items;

alter publication supabase_realtime add table sales;
