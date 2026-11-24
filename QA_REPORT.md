# 404 Gaming Zone — QA and security review

25 November 2026 · test site and test database only. The live websites and the live database were not touched.

## What was tested

| Area | How | Result |
|---|---|---|
| Booking rules in the database | 57 automated checks on a throwaway database | All passed |
| Public visitor (not signed in) | 22 probes against the test database from the booking page | Booking data closed; one leak found and fixed (below) |
| Staff login | 17 probes against the test database while signed in as staff | Cannot approve, decline, cancel, edit or delete bookings |
| Customer booking, start to finish | A real booking with an uploaded image on the test site | Worked (#1011) |
| Session add time, 30 minutes, undo, add and remove player | On running test sessions | Worked |
| Sessions and bookings linked | 17 automated checks, then on the test site: walk-in on M5, booked machines greyed out, customer timetable showed M5 as taken, booking #1007 started as a session and ended | Worked. Advance of Rs 2,400 was taken off the bill (Rs 0 to collect) and the booking closed as completed |

Not tested: Approve, Decline and "Confirm received" by clicking them as an owner on the site (the owner password is not mine to type). The database functions behind them passed their checks.

## Fixed during this review

1. **Staff saw owner buttons.** Signing in as staff inside the Sessions tab left the main page showing the previous owner's name, payments queue and Cancel button. The database refused the actions, but the screen was wrong. The page now restarts as whoever is signed in, and re-checks the role with the database every time bookings load.
2. **A booking could be made with no screenshot.** Someone calling the database directly could lock slots with a made-up file name. The database now requires a real uploaded file, and one screenshot can pay for one booking only.
3. **One phone could lock the whole timetable.** A phone number can now hold at most 5 unchecked bookings.
4. **Approve recorded what the customer claimed, not what arrived.** Approve now asks the owner for the amount actually received, and saves both figures.
5. **Two staff functions answered anyone on the internet.** `gz_session_tabs` and `gz_snacks_by_session` returned session ids and snack amounts with no sign-in. Fixed on the test database (`database/close_public_functions.sql`). **The live database has the same opening.**

## Open risks, most serious first

| # | Risk | Why it matters | What to do |
|---|---|---|---|
| 1 | ~~Bookings and sessions do not know about each other~~ **Fixed 25 Nov** | Every session now sits on a named machine (M1–M5, PS4, XBOX). A booked machine cannot be given to a walk-in, a machine in use cannot be booked, and a booking is started as a session with its advance already counted | Not tested live: the block on adding time into a later booking (no booking was close enough); it passed on the throwaway database |
| 2 | The live database has no automatic backups (free plan) | All sales, sessions and stock history sit in one place | Paid plan with daily backups, or a scheduled export |
| 3 | The live database has the opening in fix 5 | Anyone with the site's public key can read session ids and snack amounts | Run `close_public_functions.sql` on live, with the owner's approval |
| 4 | Test owner login has a weak password on a public site | Anyone who guesses it becomes owner of the test database | Change it now; never reuse it on live |
| 5 | Staff can read cost prices, profit and revenue history through the database | The apps hide them, but a staff phone still receives them | Needs a redesign of how sale cost is recorded; not a quick fix |
| 6 | Session prices are calculated on the staff device | A staff member who knows how could record a session at any price | Move pricing into the database |
| 7 | No alert when a booking arrives | A payment waits until an owner opens the Bookings tab; the customer may arrive unconfirmed | WhatsApp or push alert to owners |
| 8 | Anyone can upload images to the screenshot folder | Up to 5 MB each, images only, nobody but owners can view them, but they use storage | Clean-up of files not attached to a booking; watch storage use |
| 9 | Payment screenshots are personal data | They show names and account numbers | Decide how long to keep them and delete older ones |
| 10 | Pending bookings never expire | An unchecked booking stays "pending" after its time has passed | Decide a rule; not automated because it could drop a paid booking |
| 11 | A booking number plus phone number shows that booking | Numbers run in order, so someone who knows a phone number could try numbers | Low risk; add a random receipt code if it becomes a problem |
| 12 | Saving Settings in the Sessions tab replaces all settings | It would wipe booking prices and account details once those are stored there | Fix before adding booking settings |
| 13 | Refund and credit are handled by hand | Cancelling keeps the amount on record but moves no money | Write the policy on the booking page and in staff notes |
| 14 | Free hosting and free database | The test database pauses after a week unused; limits on storage and traffic | Fine for testing; choose paid plans before launch |

## Changes that must be applied to the live database at launch

`booking_tables.sql`, `half_hours.sql`, `close_public_functions.sql`, `link_sessions_bookings.sql`. Nothing has been applied to live.
