-- =====================================================================
-- 404 Gaming Zone: half hours in a session   (TEST DATABASE ONLY for now)
--
-- Staff can now add 30 minutes to a running session, so "hours paid" can be
-- 1.5 or 2.5. The two columns that hold it were whole numbers, and the
-- function that ends a session read it as a whole number. Safe to re-run.
-- =====================================================================

alter table gz_sessions alter column paid_hours type numeric using paid_hours::numeric;
alter table gz_history  alter column paid_hours type numeric using paid_hours::numeric;

-- Identical to the function already in use, except paid_hours is read as a
-- number that may have a half in it (was ::int).
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
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;

  insert into gz_history (
    id, platform, game, player_count, player_names,
    start_time, end_time, paid_hours, hourly_rate,
    price_segments, revenue, ended_by,
    pay_method, cash_amount, online_amount
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
    -- The WHOLE bill: the gaming plus whatever was on the customer's snack
    -- tab, because that is what they actually handed over.
    cash,
    onl
  )
  on conflict (id) do nothing;

  -- Settle the snack tab for this session. The rows take the session's label
  -- but deliberately no amounts: the session row already holds the whole bill.
  update sales
     set pay_method = coalesce(pay_method, method),
         settled_at = now()
   where gz_session_id = p_id
     and settled_at is null
     and coalesce(voided,false) = false;

  delete from gz_sessions where id = p_id;
  return true;
end;
$function$;
