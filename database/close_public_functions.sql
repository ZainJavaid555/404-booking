-- =====================================================================
-- 404 Gaming Zone: staff-only functions must not answer the public
--
-- Found in testing on 25 Nov 2026: most database functions were granted to
-- "anon" (anyone on the internet holding the site's public key). All but two
-- refuse inside with "not signed in", but gz_session_tabs and
-- gz_snacks_by_session had no such check and returned session ids and snack
-- amounts to anyone. This takes the public grant away from every function
-- that is meant for signed-in staff. The four customer functions stay public:
--   gz_public_slots, gz_public_booking_info, gz_create_booking, gz_booking_status
-- is_owner() stays callable because the row rules themselves call it.
-- Safe to re-run.  APPLIED TO THE TEST DATABASE ONLY SO FAR.
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and p.proname in ('adjust_stock','delete_delivery','delete_item_history','gz_add_to_tab',
                         'gz_end_session','gz_session_tabs','gz_set_payment','gz_set_payment_split',
                         'gz_set_tab_lines','gz_snacks_by_session','gz_void_session','record_count',
                         'record_purchase','record_purchase_backdated','gz_decide_booking',
                         'gz_cancel_booking','gz_release_booking','sales_backdate_guard',
                         'sales_guard_amount','gz_sessions_guard_delete')
  loop
    execute format('revoke execute on function %s from anon, public', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
