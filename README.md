# 404 Gaming Zone — development sandbox

This repo is a **separate working copy** for building the booking system
("Build Your Own Slot"). It is not connected to the live websites or the live
database. Nothing here goes live until it is finished, tested, and moved into
the live repos on purpose.

## Rules

1. **Never point this code at the live database.** `admin/index.html` and
   `snacks/index.html` point at the **test** Supabase project `404-test`
   (`bxviqxrbyjtsrfwtmsbe`). The live project's address must never appear in
   the config of this repo.
2. **No changes to the live websites from here.** Live code lives in its own private repos.
3. **Keep the existing design.** New booking screens use the same look as the
   current admin and snacks apps.
4. **No secrets in Git.** No database password, no service key.

## What is in here

| Folder | What it is |
|---|---|
| `index.html` | The one website: staff sign in once, then Sessions, Snacks and Bookings in one place |
| `book/` | Customer page: Build Your Own Slot (no sign-in) |
| `admin/` | Session manager (copy of `admin404`, 24 Nov 2026), with game cover images |
| `snacks/` | Snacks counter app (copy of `snacks`, 24 Nov 2026) |
| `database/full_schema.sql` | Full structure of the live database (no data), exported 24 Nov 2026 |
| `QA_REPORT.md` | What was tested, what was fixed and the open risks (25 Nov 2026) |
| `database/close_public_functions.sql` | Removes public access from staff-only database functions |
| `database/half_hours.sql` | Lets a session hold half hours (30-minute add-ons) |
| `database/booking_tables.sql` | DRAFT: machines, bookings and payment proofs for the booking system |
| `database/*.sql` (other) | The original snacks SQL files from the source repo |

## Still to add

- Snacks product photos (`snacks/products/`), which are missing from the source repo
- Test logins (an owner and a staff user) in the `404-test` project
- Payments queue: show the transaction ID and the payer's name; when the screenshot shows only an amount, ask the customer for the name or transaction ID
- Walk-in and manual bookings, starting a session from a booking, cancellations
- Merging Sessions and Snacks into the main page properly (today they are shown inside it)
