-- =====================================================================
-- 404 Gaming Zone — phone alerts for new bookings (web push)
-- Run AFTER booking_tables.sql. Safe to run twice.
--
-- How it works:
--   1. An owner taps "Turn on alerts" on their phone. The phone's address
--      for notifications is saved in gz_push_subs.
--   2. When a customer books, the trigger below pings the Edge Function
--      "booking-alert" (source: database/booking-alert.function.ts).
--   3. The function sends a notification to every saved owner phone.
--
-- The function is safe to be called by anyone: it never trusts what it is
-- sent. It only alerts for pending bookings that have not been alerted yet.
--
-- !! AT LAUNCH: change the project address in gz_bookings_alert() below
--    to the live project's address, and deploy the function there too.
-- =====================================================================
create extension if not exists pg_net with schema extensions;

alter table gz_bookings add column if not exists alerted_at timestamptz;
update gz_bookings set alerted_at = now() where alerted_at is null;   -- old bookings never alert

-- One row per owner phone / browser.
create table if not exists gz_push_subs (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  device     text,
  created_at timestamptz default now()
);
alter table gz_push_subs enable row level security;
drop policy if exists "push_subs_own_read" on gz_push_subs;
create policy "push_subs_own_read" on gz_push_subs for select using (user_id = auth.uid());
-- no insert / update / delete policy: only the two functions below write here.

-- The signing keys for notifications. Made by the Edge Function the first
-- time it runs. RLS is on with no policy, so no login can read this table.
create table if not exists gz_push_keys (
  id          integer primary key check (id = 1),
  public_key  text not null,
  private_key text not null
);
alter table gz_push_keys enable row level security;
revoke all on gz_push_keys from anon, authenticated;

create or replace function gz_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not is_owner() then raise exception 'only owners get booking alerts'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'bad address'; end if;
  insert into gz_push_subs (user_id, endpoint, p256dh, auth, device)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_device, 160))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, device = excluded.device;
end $$;

create or replace function gz_push_unsubscribe(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from gz_push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke all on function gz_push_subscribe(text, text, text, text) from public, anon;
revoke all on function gz_push_unsubscribe(text) from public, anon;
grant execute on function gz_push_subscribe(text, text, text, text) to authenticated;
grant execute on function gz_push_unsubscribe(text) to authenticated;

-- Ping the Edge Function after a booking is saved. A failure here must
-- never stop a booking, so every error is swallowed.
create or replace function gz_bookings_alert()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  begin
    perform net.http_post(
      url     := 'https://bxviqxrbyjtsrfwtmsbe.supabase.co/functions/v1/booking-alert',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body    := '{}'::jsonb
    );
  exception when others then null;
  end;
  return new;
end $$;

drop trigger if exists gz_bookings_alert_trg on gz_bookings;
create trigger gz_bookings_alert_trg
  after insert on gz_bookings
  for each row when (new.state = 'pending')
  execute function gz_bookings_alert();

select 'push tables' as "check", count(*)::text as installed from information_schema.tables where table_name in ('gz_push_subs','gz_push_keys')
union all select 'alert trigger', count(*)::text from pg_trigger where tgname = 'gz_bookings_alert_trg';
