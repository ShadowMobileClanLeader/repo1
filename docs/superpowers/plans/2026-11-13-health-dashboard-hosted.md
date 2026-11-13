# Personal Health Dashboard (Hosted) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A private health dashboard, hosted on Vercel with data in Supabase. It's filled from my Garmin export, imported in the browser, and then by a daily sync from the Garmin Personal API.

**Architecture:**
- A static site (`web/`, plain ES modules, no build step) is deployed on Vercel. It signs in with Supabase Auth and reads and writes only my rows through RLS.
- Pure logic lives in `web/lib/` (inventory, normaliser, metrics) and is shared by the browser and the Deno Edge Function `garmin-sync`, which pg_cron runs daily.

**Tech Stack:**
- Supabase: Postgres, Auth, Edge Functions (Deno), pg_cron, pg_net, Vault
- Vercel static hosting
- JS libraries from pinned CDNs: `@supabase/supabase-js@2.45.4`, `@observablehq/plot@0.6.16`, `d3@7.9.0`, `jszip@3.10.1`
- Tests: Node 20+ `node --test`, with no npm dependencies

**Spec:** `docs/superpowers/specs/2026-11-13-health-dashboard-hosted-design.md`. Calculations and layout come from `docs/superpowers/specs/2026-11-13-health-dashboard-design.md` §7, §8 and §10. The reference implementation of the layout and metrics is the approved preview, `https://claude.ai/artifact/BnE2dKhxT5RLBdpLCqmZwR`; its source is saved in the repo as `web/reference/preview.html` in Task 1.

**Execution:** Native, in this cloud session. Each **Phase** ends with a **CHECK-IN** with me, and the next phase waits for my go-ahead.

## Global Constraints

- **Supabase:** org `hffuwzboqpkihruphitp` (free plan), new project `health-dashboard`, region `us-east-2`. Never touch the existing project `dyoowadyyfjjiskvrnuw`.
- **Vercel:** team `team_Gu2TqoM4UtwpY1DNbC72I9Zl`, new project `health-dashboard`. Never touch `schooling-dashboard`.
- **Database tables:** every table has `user_id uuid not null default auth.uid()` and RLS enabled, with owner-only policies (`user_id = (select auth.uid())`) for select, insert, update and delete. Natural keys include `user_id`.
- **Writes go only through SQL functions** `upsert_daily(jsonb)`, `upsert_weight(jsonb)`, `upsert_activities(jsonb)`, `upsert_vo2max(jsonb)` and `upsert_profile(jsonb)`. Each takes an array of records, uses `coalesce(excluded.col, t.col)`, and returns `{inserted, updated, unchanged}`.
- **Database values are in SI units.** Imperial conversion happens only in `web/lib/units.js`.
- **Implausible flags:** resting heart rate below 25 or above 120, or a weight change of more than 4.536 kg (10 lb) from the previous weigh-in. These are set by the upsert functions.
- **Allowed in the repo or on Vercel:** only the Supabase URL and the *publishable* key. The service-role key, Garmin key and health data must never appear in the repo, Vercel env or chat output. The Garmin key is set by me in Supabase → Edge Functions → Secrets as `GARMIN_PERSONAL_API_KEY`.
- **The cron secret** is generated inside Postgres (`gen_random_uuid()`), stored in Vault as `garmin_cron_secret`, and never printed.
- **CSP** (in `web/vercel.json`): `default-src 'self'`; `script-src 'self' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com`; `connect-src 'self' https://<project-ref>.supabase.co`; `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com`; `font-src https://fonts.gstatic.com`; `img-src 'self' data:`; `frame-ancestors 'none'`.
- **Fixed copy** (verbatim, from the local plan's Global Constraints): the footer, the health index label, the energy label, and "Correlation, not cause."
- **Default settings:** `weight_goal = 'maintain'`, `sleep_band_h = [7,9]`, `easy_hr_band = [140,150]`.
- **Tests use fake data only.** Shell commands that touch health data print counts and dates, never values.

## Review Focus

1. **A second account somehow exists,** for example if sign-ups are re-enabled by mistake. Its user sees zero of my rows. (A database test in Task 2 creates two users, and each sees only its own rows.)
2. **A large real export** (years of data, hundreds of files). The import stays responsive, shows progress per file and batch, and finishes. (A test in Task 6 imports a fake 3-year export of 40 files in a Node simulation and checks there are at most 500 rows per call.)
3. **An overlapping import plus sync** for the same days. No duplicates, and no value is blanked. (Tests in Tasks 2 and 10.)
4. **The Garmin key is missing or expired.** The sync logs a clear error, and the dashboard header shows it. Nothing crashes. (Test in Task 9.)
5. **The session expires mid-import.** The import stops and shows "Your sign-in expired. Sign in again and re-run the import; everything already imported is kept." (Test in Task 6.)

---

## File Structure

```
web/index.html            # dashboard (requires sign-in)
web/signin.html
web/import.html
web/settings.html
web/vercel.json           # CSP + security headers, cleanUrls
web/styles.css            # tokens from the preview
web/app/supabase.js       # client init (URL + publishable key), requireSession()
web/app/dashboard.js      # render code ported from the preview, data from Supabase
web/app/import.js         # ZIP → inventory → confirm → batched upserts
web/app/settings.js
web/lib/units.js
web/lib/inventory.js      # inventoryFromFiles(files) → report (no values)
web/lib/normalize.js      # export + API shapes → records
web/lib/metrics.js        # rolling7, healthIndex, reportCard, energy, running, correlation
web/lib/*.test.js         # node --test
web/reference/preview.html
supabase/migrations/0001_init.sql
supabase/migrations/0002_cron.sql
supabase/functions/garmin-sync/index.ts   # imports ../../../web/lib/normalize.js
package.json              # {"type":"module","scripts":{"test":"node --test web/lib/"}}
README.md
```

---

## Phase A: Foundation, database and sign-in

### Task 1: Replace the Python scaffold with the JS layout

**Files:**
- Delete: `hd/`, `tests/`, `pyproject.toml`, `.python-version`, `uv.lock`, `config.example.toml`
- Create: `package.json`, `web/lib/units.js`, `web/lib/units.test.js`, `web/reference/preview.html` (copied from the published preview)
- Modify: `.gitignore`. Keep the private entries, and add `node_modules/` and `.vercel/`.

**Interfaces:**
- Produces in `web/lib/units.js`: `kgToLb(x)`, `mToMi(x)`, `paceSecPerKmToSecPerMi(x)`, `fmtPace(secPerMi)`, `fmtHM(hours)`. All return `null` when given `null` or `undefined`.

- [ ] **Step 1: Write failing tests**
  - `kgToLb(75) ≈ 165.347` (to 3 decimal places)
  - `mToMi(1609.344) === 1`
  - `paceSecPerKmToSecPerMi(360) ≈ 579.36`
  - `fmtPace(579.36) === "9:39"`
  - `fmtHM(7.7) === "7 h 42 m"`
  - every function returns `null` for `null`
- [ ] **Step 2: Run `node --test web/lib/`.** Expected: FAIL (module not found).
- [ ] **Step 3: Implement `units.js`, delete the Python files, and add `package.json`.** Copy the published preview source (the scratchpad file published as the approved preview) into `web/reference/preview.html`.
- [ ] **Step 4: Run `node --test web/lib/`.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "chore: switch to hosted JS layout; units module"`.

### Task 2: Supabase project, schema, RLS and upsert functions

**Files:**
- Create: `supabase/migrations/0001_init.sql`

**Interfaces:**
- Produces:
  - **Tables** (columns as in local spec §5, with SI names):
    - `daily(user_id, date, steps, distance_m, resting_hr, hrv_night_ms, sleep_s, sleep_score, stress_avg, body_battery_high, body_battery_low, kcal_total_garmin, kcal_active_garmin, kcal_bmr_garmin, flagged bool default false, source text, updated_at timestamptz)`, unique on `(user_id, date)`
    - `weight(user_id, date, weight_kg, body_fat_pct, flagged, source)`, unique on `(user_id, date)`
    - `activities(user_id, activity_id bigint, start_utc timestamptz, local_date date, type, distance_m, duration_s, avg_hr, max_hr, kcal, steps, elev_gain_m, training_load, source)`, unique on `(user_id, activity_id)`
    - `vo2max(user_id, date, sport, value)`, unique on `(user_id, date, sport)`
    - `profile(user_id primary key, height_cm, birth_date, sex check in ('male','female'))`
    - `settings(user_id primary key, weight_goal default 'maintain', sleep_band_lo default 7, sleep_band_hi default 9, easy_hr_lo default 140, easy_hr_hi default 150)`
    - `sync_log(id bigserial, user_id, ran_at timestamptz default now(), ok bool, fetched jsonb, error text)`
  - **RPCs:** `upsert_daily(rows jsonb) returns jsonb`, and the same shape for weight, activities, vo2max and profile. They are `security invoker`, so RLS applies.

- [ ] **Step 1: Create the Supabase project** `health-dashboard` in org `hffuwzboqpkihruphitp`, region `us-east-2`, using the Supabase MCP `create_project`. Confirm the cost is $0 first (free plan, 2nd active project). Record the project ref in the ledger.
- [ ] **Step 2: Write the migration `0001_init.sql`:**
  - the tables
  - an index on `daily(user_id, date)`
  - RLS enabled, with 4 owner policies per table using `(select auth.uid())`
  - the upsert functions, which also set the `flagged` column
  - `revoke all on all tables in schema public from anon`
- [ ] **Step 3: Write the failing database checks** as SQL that runs before the migration. They fail with "relation does not exist":
  - `db_anon_sees_nothing`: `set local role anon; select count(*) from daily` returns 0 (or permission denied)
  - `db_two_users_isolated`: insert rows as user A and user B by setting `request.jwt.claims` and role `authenticated`. Each sees only its own rows.
  - `db_upsert_idempotent`: the same 3 rows twice. The second call returns `{"inserted":0,"updated":0,"unchanged":3}`.
  - `db_upsert_never_nulls`: an existing `resting_hr = 52`, followed by an upsert with `resting_hr` null and `steps` 9000, keeps 52 and sets 9000
  - `db_flags_implausible`: `resting_hr = 19` is flagged. 75 kg followed by 80 kg the next day flags the second weigh-in.
- [ ] **Step 4: Apply the migration** with `apply_migration`, then run the checks with `execute_sql`, each in a transaction that is rolled back. Expected: all pass.
- [ ] **Step 5: Run `get_advisors` (security).** Expected: no ERROR-level findings. Fix any WARN that is about this schema.
- [ ] **Step 6: Commit** with `git commit -m "feat: Supabase schema with RLS and safe upserts"`.

### Task 3: Site skeleton, sign-in and Vercel deploy

**Files:**
- Create: `web/signin.html`, `web/index.html` (placeholder: "Signed in. No data yet."), `web/styles.css` (tokens copied from the preview), `web/app/supabase.js`, `web/vercel.json`

**Interfaces:**
- Produces in `web/app/supabase.js`:
  - `supabase` (client)
  - `requireSession(): Promise<Session>`, which redirects to `/signin` if there's no session
  - `signOut()`

- [ ] **Step 1: Write the pages.**
  - **Sign-in:** a form with an email and password, and a "Create account" button visible only while `?setup=1` is in the URL.
  - **Every other page** calls `requireSession()` first.
  - **`vercel.json`** sets the CSP from Global Constraints, plus `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and `Permissions-Policy: camera=(), microphone=(), geolocation=()`.
- [ ] **Step 2: Create the Vercel project** `health-dashboard` in the team and deploy `web/` as production, through the Vercel MCP file deployment. If file upload isn't available, connect the GitHub repo with root directory `web/` and production branch `claude/practical-brown-r8iemm`, and ledger the ruling.
- [ ] **Step 3: Verify the deployment.** `curl -sI <url>` shows the CSP header. `curl <url>/signin` returns 200. A headless Chromium load of `/` redirects to `/signin` with no console errors.
- [ ] **Step 4: Commit** with `git commit -m "feat: sign-in, session guard, Vercel deploy with CSP"`.

**CHECK-IN (Phase A):**
1. I open `<url>/signin?setup=1` and create my account.
2. I turn off **Authentication → Sign In / Providers → Allow new users to sign up** in the Supabase dashboard.
3. Verify that a sign-up attempt with the publishable key now fails, and that sign-in works.

---

## Phase B: Import my export

### Task 4: Browser inventory

**Files:**
- Create: `web/lib/inventory.js`, `web/lib/inventory.test.js`, `web/lib/fixtures.js` (fake export as a file list), `web/import.html`, `web/app/import.js` (step 1 only)

**Interfaces:**
- Produces:
  - `inventoryFromFiles(files: {path: string, text: string|null}[]) → {filesByExt, folders, jsonFiles: [{path, nRecords, keys, dateMin, dateMax, parseError}], metrics: {[name]: {start, end}|null}}`
    - It uses the date keys and metric keywords from the local plan's Task 2.
    - `.json` files have their `text` filled. Other files have `text` set to `null`.
  - `formatInventory(report) → string`
  - `fakeExportFiles({years=1, files=6}) → files` in `fixtures.js`

- [ ] **Step 1: Write failing tests,** porting the Python tests:
  - counts by extension
  - the UDS date range is 2026-01-01 to 2026-04-10, with 100 records
  - the metrics detected (HRV is `null`)
  - `formatInventory` contains the key name `restingHeartRate` but never the sentinel value `173`, "fake-user" or "1986"
- [ ] **Step 2: Run `node --test web/lib/`.** Expected: FAIL.
- [ ] **Step 3: Implement `inventory.js`, then build the import page's step 1.** I pick a ZIP, JSZip reads it in the browser, and the page shows `formatInventory` plus a "Copy report" button. Nothing is sent anywhere.
- [ ] **Step 4: Run the tests (expect PASS), then redeploy.**
- [ ] **Step 5: Commit** with `git commit -m "feat: in-browser export inventory"`.

**CHECK-IN (Phase B1):**
- I run the inventory on my real export at `<url>/import` and paste the report into the chat. It holds only names, counts and dates.
- Record the layout in `docs/export-layout.md` (paths and key names only).

### Task 5: Export normaliser

**Files:**
- Create: `web/lib/normalize.js`, `web/lib/normalize.test.js`
- Modify: `web/lib/fixtures.js`, to match `docs/export-layout.md`

**Interfaces:**
- Produces:
  - `normalizeExport(files) → {daily: [], weight: [], activities: [], vo2max: [], profile: obj|null, skipped: {[reason]: n}}`
    - The record fields match the Task 2 column names exactly, in SI units.
  - `normalizeApi(endpoint, payload) → same shape`. This is a stub until Task 10.

- [ ] **Step 1: Write failing tests** (equivalents of the local plan's Task 4):
  - daily fields mapped
  - an activity at `2026-03-01T03:30:00Z` with a −8 h offset gets `local_date` 2026-02-28
  - sleep seconds and score
  - HRV present, and absent (`null`)
  - weight converted from grams to kg (unit confirmed from the real layout)
  - VO2 max records
  - profile
  - duplicate activity IDs deduplicated
  - an unknown file is counted in `skipped`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `normalize.js`.** Use one function per file family, driven by a path-pattern table.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: normalise Garmin export records"`.

### Task 6: Batched import into Supabase

**Files:**
- Modify: `web/app/import.js`
- Create: `web/lib/batch.js`, `web/lib/batch.test.js`

**Interfaces:**
- Produces:
  - `chunk(rows, size = 500) → rows[][]`
  - `runImport(records, rpc: (name, rows) => Promise<{data, error}>, onProgress) → {perTable: {[t]: {inserted, updated, unchanged}}, stoppedAt: null|{table, dateFrom}}`

- [ ] **Step 1: Write failing tests,** using a fake `rpc`:
  - `test_batches_at_most_500`: a 3-year fake export (`fakeExportFiles({years: 3, files: 40})`) never sends more than 500 rows per call (Review Focus 2)
  - `test_sums_stats_per_table`
  - `test_stops_on_401_with_message`: the fake `rpc` returns `{error: {status: 401}}` on the 3rd call. The result has `stoppedAt` set, and the message is the Review Focus 5 copy.
  - `test_progress_called_per_batch`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `batch.js`, and wire up the import page's step 2:**
  - an "Import into my dashboard" button appears after the inventory
  - a progress bar
  - a summary table showing rows, new, updated, unchanged and date range per table, plus the skipped and flagged counts
- [ ] **Step 4: Run the tests (expect PASS), then redeploy.**
- [ ] **Step 5: Commit** with `git commit -m "feat: batched import with progress and safe stop"`.

**CHECK-IN (Phase B2):** I import my real export, then import it again.
- **Acceptance:**
  - the counts and date ranges look right to me
  - the second run shows 0 new and 0 updated
  - checked with `execute_sql`, printing counts only: no rows belong to any user other than me

---

## Phase C: Dashboard on my data

### Task 7: Metrics module

**Files:**
- Create: `web/lib/metrics.js`, `web/lib/metrics.test.js`

**Interfaces:**
- Produces:
  - `rolling7(values, minN = 4)`
  - `carryForward(values, maxDays = 14)`
  - `healthIndex(dailySeries, settings) → [{date, rhr, hrv, sleep, weight, index}]`
  - `reportCard(dailySeries, weeklyMiles, settings, months = 12) → [{month, cells}]`
  - `restingKcal(kg, cm, age, sex)`
  - `dailyEnergy(days, runs, profile) → [{date, rest, stepsK, workK, tef, est, garmin}]`
  - `calculatorParams(...)`
  - `weeklyBuckets(days, runs)`
  - `easyPace(runs, band)`
  - `loadHrvCorrelation(weeks) → {r, n}`

  These are ported from the preview's inline functions, unchanged in behaviour.

- [ ] **Step 1: Write failing tests:**
  - `restingKcal(75, 180, 40, "male") === 1680`, and `"female"` gives 1514
  - energy worked example: `est ≈ 2618.69`
  - the stride fallback is 0.7452 m
  - index: 50 at baseline, 65 at +1 SD, clamped to 0 and 100, the sleep band distance rule, maintain scores 35 at ±1 SD, fewer than 3 components gives `null`, fewer than 60 baseline days gives `null`
  - report card: better above 0.5 SD, same within, "not enough data" under 10 days, and weight on maintain gives same or worse only
  - `rolling7` needs 4 values
  - correlation on a known series: `r = -1`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `metrics.js`,** porting from `web/reference/preview.html`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: shared metrics module with worked-example tests"`.

### Task 8: Dashboard and settings pages

**Files:**
- Modify: `web/index.html`
- Create: `web/app/dashboard.js`, `web/settings.html`, `web/app/settings.js`

**Interfaces:**
- Consumes: `metrics.js`, `units.js` and `supabase.js`
- Produces: `loadAll(supabase) → {days, weights, runs, vo2, profile, settings, lastSync}`. It pages through PostgREST 1,000 rows at a time.

- [ ] **Step 1: Write failing tests** for `web/lib/shape.js`, the pure conversion from database rows to the arrays the preview renderer expects:
  - `test_rows_to_days_fills_missing_dates`
  - `test_runs_filter_types`, where `RUN_TYPES` is set from the real layout
  - `test_profile_missing_disables_energy`: the energy section shows "Add your height, birth date and sex in Settings to see energy estimates."
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement it.**
  - **`dashboard.js`** reuses the preview's render functions with the sample generator removed and the sample banner removed. The header shows the last sync time, or its error.
  - **The settings page** edits `profile` and `settings` through `upsert_profile` and the `settings` table.
- [ ] **Step 4: Run the tests (expect PASS), then redeploy.** Check in headless Chromium that an unauthenticated visit redirects to `/signin` with no console errors. No test accounts are created, because sign-ups are off, so the signed-in view is verified by me at the check-in. Say so in the report.
- [ ] **Step 5: Commit** with `git commit -m "feat: dashboard and settings on live data"`.

**CHECK-IN (Phase C):** I enter my profile in Settings and review the dashboard.
- **Acceptance:**
  - the tiles match Garmin Connect, within rounding
  - every section renders
  - the range toggle works
  - it's usable on my phone

---

## Phase D: Daily Garmin sync

### Task 9: Edge Function with auth guard and connection check

**Files:**
- Create: `supabase/functions/garmin-sync/index.ts`

**Interfaces:**
- Produces: `POST /functions/v1/garmin-sync` with body `{mode: "probe"|"sync", days?: number}`
  - **Authorization:**
    - either my user JWT, checked with `supabase.auth.getUser()` (my user id is read from the JWT, not hard-coded)
    - or the cron secret in header `x-cron-secret`, compared with the Vault value
  - **Probe mode** returns `[{endpoint, status, fields: string[]}]`, field names only.

- [ ] **Step 1: Deploy a stub** that returns 501 to every request, so the checks below fail first.
- [ ] **Step 2: Write failing checks (Review Focus 4):**
  - a call with no auth returns 401
  - a call with the publishable key only returns 401
  - a call with my session and the key unset returns `{error: "GARMIN_PERSONAL_API_KEY is not set"}` and writes a `sync_log` row with `ok = false`
- [ ] **Step 3: Implement the remaining behaviour** to pass the checks. The token exchange POSTs to `https://personal.connectapi.garmin.com/personalapitoken-service/personal-api/personal-api-key/token` with the header `Authorization: ApiKey <key>`. The key is never logged.
- [ ] **Step 4: Run the checks** with `curl` and `execute_sql` on `sync_log`, printing only `ok` and `error`. Expected: all pass.
- [ ] **Step 5: Add a "Check Garmin connection" button to Settings,** then commit with `git commit -m "feat: garmin-sync function with auth guard and probe"`.

**CHECK-IN (Phase D1):**
1. I create a Personal API key in Garmin Connect (1-year expiry).
2. I add it in Supabase → Edge Functions → Secrets as `GARMIN_PERSONAL_API_KEY`.
3. I press "Check Garmin connection".
4. We agree the endpoint→table mapping from the field names. VO2 max is expected to stay export-only.

### Task 10: Sync, schedule and Refresh button

**Files:**
- Modify: `web/lib/normalize.js` (`normalizeApi`), `supabase/functions/garmin-sync/index.ts`, `web/app/dashboard.js`
- Create: `supabase/migrations/0002_cron.sql`

- [ ] **Step 1: Write failing tests:**
  - `normalizeApi` produces records equal to `normalizeExport` for the same fake day, apart from `source`
  - local dates of API activities
  - an overlap test: importing fake export rows and then fake API rows for the same day keeps the union of the values (Review Focus 3)
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement sync mode:**
  - it pulls `days` (default 7) per agreed endpoint, sequentially
  - it upserts through the RPCs, using the service role inside the function and setting `user_id` from the JWT (or, for cron, for each `user_id` in `settings`, which is just me)
  - it writes `sync_log`
  - on a 429 it stops and logs the error
- [ ] **Step 4: Write `0002_cron.sql`:**
  - enable `pg_cron` and `pg_net`
  - create the Vault secret `garmin_cron_secret` with `gen_random_uuid()`
  - add the `cron.schedule('garmin-sync-daily', '17 6 * * *', …net.http_post…)` call with the `x-cron-secret` header, reading the secret from `vault.decrypted_secrets`
  - set the function to compare against the same Vault value

  Apply it.
- [ ] **Step 5: Add the "Refresh now" button** to the dashboard header. It calls sync mode, then reloads the data and shows "Synced N days" or the logged error.
- [ ] **Step 6: Run the tests (expect PASS), trigger one sync manually** (with my session at the check-in), and confirm `cron.job` lists the job. Then commit with `git commit -m "feat: daily Garmin sync, schedule, refresh button"`.

### Task 11: Security gates and README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run all 6 security gates from spec §5** and record the evidence in the ledger:
  1. the advisors report
  2. anon read count of 0
  3. a sign-up attempt fails
  4. `git grep -nE "service_role|sb_secret|eyJhbGciOi[^\"]{80,}|GARMIN_PERSONAL_API_KEY="` finds no secrets (the variable *name* only appears in docs), and the Vercel env list is reviewed
  5. the function returns 401 without auth
  6. the response headers include the CSP
- [ ] **Step 2: Write the README.** Keep it short. Sections:
  - what it is
  - where the data lives (the table from the spec)
  - how to import a new export
  - how sync works and how to renew the Garmin key yearly (Garmin emails a week before expiry)
  - how to change settings
  - what to do if Supabase pauses the project
- [ ] **Step 3: Commit and push** with `git commit -m "docs: README; security gates verified"`.

**CHECK-IN (Phase D, final):**
- **Acceptance:**
  - the next morning's automatic sync shows up in the header
  - "Refresh now" works
  - the dashboard shows yesterday's data without a new export
