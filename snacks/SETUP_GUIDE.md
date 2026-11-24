# 404 Snacks — how it works

The snacks counter for 404 Gaming Zone. Sales, stock and reports, shared live
between the counter phone and the owners' phones.

---

## Logins

| Email | Role |
|---|---|
| owner-1@example.com | Owner |
| owner-2@example.com | Owner |
| staff@example.com | Staff — the counter |

**The staff login is not tied to a person.** It is the counter's login. When the
person working the counter changes, nothing needs changing here — just tell the
new person the email and password. If you ever want to stop the old person using
it, change the password (see below).

Sign-in is once per device. The app stays signed in and keeps working offline.

---

## Putting it on the phones

1. Go to **app.netlify.com/drop** and drag the whole `snacks_web` folder in.
   You get a link straight away, free, over https.
2. Open the link on each phone.
3. Chrome: menu (⋮) → **Install app**. Safari: Share → **Add to Home Screen**.
4. Sign in once. Done.

It must be served over https. Opening the file directly from the phone's
storage will not save data reliably.

---

## Who can do what

The database enforces this, not just the app. Even someone bypassing the app
entirely cannot get around it.

| | Staff | Owner |
|---|---|---|
| Sell items | Yes | Yes |
| See stock | Yes | Yes |
| See today's takings | Yes | Yes |
| Void a mistake | Own sale, within 18 hours | Any sale |
| See cost price and profit | **No** | Yes |
| Add / edit / delete products | **No** | Yes |
| Change prices | **No** | Yes |
| Add stock | **No** | Yes |
| Reports and CSV export | **No** | Yes |

**No one can delete a sale — not even an owner.** Mistakes are voided, which
leaves a visible record with a reason attached. That is deliberate.

---

## Day to day

**Selling.** Tap **+** and **−** on each product to set quantities, then
**Checkout**. Tapping the card itself does nothing, so a stray touch costs
nothing. Stock drops automatically.

**Mistakes.** Tap ✕ on the sale and pick a reason. Stock is returned, the sale
stays in the record marked VOID, and it shows in the owner's reports.

**Restocking.** Owner → **Stock** tab → **+** next to the item.

**Reports.** Owner → **Reports**. Filter by Today / 7 days / Month / All, with a
day-by-day breakdown and a CSV export.

**The trading day runs 4am to 4am**, so a sale at 2am counts toward the night
that produced it rather than starting a new day mid-shift.

**Daily cash check.** Reports shows the snack takings. Add the session revenue
from your website — that is what should be in the till.

---

## Changing the team

**New person on the counter:** nothing to do. Same login.

**Stop the old person having access:** Supabase → Authentication → Users →
click `staff@example.com` → reset the password. Then sign in again on the counter
phone with the new one.

**Add another owner:**
1. Supabase → Authentication → Users → **Add user**, tick *Auto Confirm User*.
2. SQL Editor:
   ```sql
   insert into profiles (id, name, role)
   select id, 'Owner', 'owner' from auth.users where email = 'their@email'
   on conflict (id) do update set name = excluded.name, role = excluded.role;
   ```
   Use `'Staff','staff'` instead for a second counter login.

**Check who has access:**
```sql
select u.email, p.name, p.role from profiles p join auth.users u on u.id = p.id;
```

---

## Offline

The app keeps working with no internet. Sales are saved on the phone and pushed
when the connection returns. The dot at the top-left is green when synced, amber
when offline. If it ever says **NOT SAVING**, stop and tell Zain — that means
the phone's storage is refusing writes.

---

## If something goes wrong

**"Local only" in the header** — the app cannot reach the database. Check the
internet; sales are still being recorded on the phone.

**A phone shows old products** — it is running a cached copy. Close the app
fully and reopen, or clear the site data once.

**Someone cannot sign in** — check they exist under Authentication → Users and
have *Auto Confirm User* ticked, and that they have a row in `profiles`.

**Products missing after sign-in** — only an owner uploads the catalogue. Sign
in as an owner and press ⟳.

---

## The project

- Supabase project **Snacks & Drinks**, region Seoul
- `(the live project URL)`
- Free tier: far more than a snack counter will use. Free projects pause after
  about a week of no activity; daily use keeps it awake.
- Schema and rules are in `database.sql`, safe to re-run.
