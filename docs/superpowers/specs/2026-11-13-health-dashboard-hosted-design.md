# Personal Health Dashboard: Hosted Design (Vercel + Supabase)

- **Date:** 2026-11-13
- **Status:** Draft for review
- **Supersedes:** sections 4, 6, 9, 11 and 12 of `2026-11-13-health-dashboard-design.md` (the local design).
- **Still applies from that spec, unchanged:**
  - §1 Purpose
  - §2 Scope, except "no hosting"
  - §5 Data model fields
  - §7 Layout, as shown in the approved preview
  - §8 Calculations
  - §10 Health content rules
- **Approved preview:** https://claude.ai/artifact/BnE2dKhxT5RLBdpLCqmZwR

## 1. Why the change

I can't run the dashboard on my MacBook. So the dashboard is hosted and opened in a browser from any device. My health data is stored in a database I own, behind my login.

## 2. What is stored where

| Place | What it holds | Who can read it |
|---|---|---|
| **Supabase project `health-dashboard`** (new, separate from the schooling project; free plan; region `us-east-2`) | **Database:** daily metrics, weigh-ins, activities, VO2 max, profile (height, birth date, sex), settings and a sync log.<br>**Auth:** my login email and password hash.<br>**Edge Function secret:** my Garmin Personal API key. | Only my signed-in account, enforced by row-level security on every table. The sync function runs with Supabase's server-side service role, which never leaves Supabase. |
| **Vercel project `health-dashboard`** | Only the website's static files (HTML, JS, CSS), plus the Supabase project URL and *publishable* key. That key is public by design and grants nothing without my login. | Anyone can load the page shell. No health data is in it. |
| **My browser** | The export ZIP while I import it: it's read in the browser and only the extracted rows are sent to Supabase. A remembered time range (localStorage). | Me |
| **GitHub repo** (`repo1`) | Code, docs and fake test fixtures only. **Never** health data or keys. | Repo collaborators |

**Not stored anywhere:**
- the raw export ZIP
- my Garmin password, because the Personal API uses a key, not a password

Health data flows directly between my browser and Supabase, and between Garmin and Supabase. It never passes through Vercel.

## 3. Architecture

```
Browser ──(login, reads/writes via RLS)──► Supabase Postgres ◄──(service role)── Edge Function garmin-sync ◄── pg_cron, daily
   │                                                                                   │
   └─ loads static site from Vercel                                                     └──► Garmin Personal API (key in Supabase secret)
```

- **Frontend:** a static site in `web/`, deployed by Vercel from this repo's branch.
  - No build step: plain ES modules.
  - Libraries load from pinned CDN URLs: Observable Plot 0.6.16, d3 7.9.0, supabase-js 2.x (pinned exact), and JSZip 3.10.1.
  - Static hosting keeps the attack surface and the moving parts small.
- **Pages:**
  - **Sign in.**
  - **Dashboard:** the approved preview layout, reading from Supabase.
  - **Import:**
    1. Pick the export ZIP.
    2. See an inventory: file names, counts, dates and metrics found, with **no values** shown.
    3. Confirm.
    4. Rows are upserted in batches.
  - **Settings:** profile, weight goal, sleep band, easy heart-rate band, and Garmin sync status.
- **Shared logic:** `web/lib/` holds pure ES modules: normalising records, the inventory, and the metrics (rolling averages, index, report card, energy, running).
  - The browser imports them.
  - The Edge Function imports the normaliser (Deno runs the same ESM).
  - Unit tests run with `node --test`.
- **Database:**
  - Postgres tables `daily`, `weight`, `activities`, `vo2max`, `profile`, `settings` and `sync_log`.
  - Each has `user_id uuid not null default auth.uid()`.
  - RLS on every table: `user_id = auth.uid()` for select, insert, update and delete.
  - Natural-key uniques include `user_id`.
- **Auth:**
  - Email and password through Supabase Auth.
  - After I create my account, **new sign-ups are turned off** in Supabase Auth settings, so nobody else can register.
- **Garmin sync:**
  - **The `garmin-sync` Edge Function:**
    1. Reads `GARMIN_PERSONAL_API_KEY` from Supabase secrets. I enter it in the Supabase dashboard myself, never in the chat.
    2. Exchanges it for a 24-hour token.
    3. Pulls the last 7 days.
    4. Normalises the data with the shared module and upserts it.
    5. Writes `sync_log`.
  - **Scheduling:** pg_cron + pg_net call the function daily at 06:17 UTC, authenticated with a random cron secret stored in Supabase Vault.
  - **On demand:** a "Refresh now" button calls the same function with my session token, and the function checks that it's me.
  - The daily write is real database activity, which should keep the free project from auto-pausing after 7 days.

## 4. Data handling rules

These are carried over from the local spec, now enforced in Postgres and the shared modules.

- **Day key:** Garmin `calendarDate`, the device's local date. Activities use their local start date, with UTC stored alongside.
- **Upserts:** `insert … on conflict (user_id, key) do update set col = coalesce(excluded.col, table.col)`, so a value is never replaced with null. This is done through a Postgres function `upsert_daily(jsonb)`, and equivalents for the other tables, called by both import and sync. Re-imports are idempotent.
- **Gaps** stay null.
- **Units:** stored in SI; imperial only in the UI.
- **Implausible values** are kept but flagged by the same thresholds: resting heart rate below 25 or above 120 bpm, or a weight change of more than 10 lb from the previous weigh-in.
- **Imports are batched** at 500 rows per call. A failed batch stops the import and reports which date range is already stored. Re-running is safe because upserts are idempotent.

## 5. Security checklist (acceptance gates)

1. **RLS is on for every table.** Supabase security advisors report no errors.
2. **The anon key can read nothing.** A request with only the publishable key returns 0 rows from every table, verified by a test query.
3. **Sign-ups are disabled** after my account exists. A sign-up attempt fails.
4. **Secrets stay out of public places.** No service-role key, Garmin key or health data in the repo or Vercel. Checked by a repo grep plus Vercel env review.
5. **The Edge Function rejects callers** that are neither the cron secret nor my session (401).
6. **The site sends a strict CSP header** (via `vercel.json`): scripts only from self and the pinned CDNs, and connections only to the Supabase project URL.

## 6. Error handling

- **Import:** unknown files are skipped and counted. Parse errors are reported per file. Batch failures are explained.
- **Sync:**
  - a Garmin 401 is logged as "key expired or invalid: create a new key in Garmin Connect settings and update the secret in Supabase"
  - a 429 response or a network error is logged, and the sync retries at the next scheduled run
  - the dashboard header shows the last successful sync and any error
- **No data:** sections show "No data yet".

## 7. Testing

- **Unit tests** (`node --test`, fake fixtures):
  - the normaliser, covering export and API shapes, local dates, units, and never overwriting a value with null
  - the inventory, which never outputs values
  - the metrics, using the spec §8 worked examples: Mifflin 1680/1514, and an energy estimate of 2618.69
  - index scaling, report card thresholds, and gap rules
- **Database tests** (SQL via Supabase):
  - RLS denies the anon key
  - an owner can read and write their own rows
  - upsert functions are idempotent and never overwrite with null
- **Deployed checks** at each phase: the site loads, sign-in works, and the security gates above pass.

## 8. Cost

- **$0 on current free plans.** Supabase free allows 2 active projects; this will be the second.
- **Limits to know:**
  - **Free Supabase projects pause after a week without database activity.** The daily sync should prevent that.
  - **If a project pauses,** it can be restored from the dashboard.

## 9. What happens to the Python code already on the branch

The Python inventory (Phase 1) is replaced by the browser inventory on the import page, because nothing runs on my Mac anymore. The Python package, tests and `pyproject.toml` are removed in the first build phase.

## 10. To confirm during the build

1. **Which endpoints and fields my Personal API key exposes.** The Settings page will have a "Check Garmin connection" button that lists them, field names only.
2. **My real export layout.** The import page's inventory step shows it before anything is stored.
3. **My profile and settings,** which I enter on the Settings page.
