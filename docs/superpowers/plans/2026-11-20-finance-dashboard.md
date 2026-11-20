# Personal Finance Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A private, hosted dashboard that shows where my money goes. It's fed automatically from my Grow Financial accounts through Plaid.

**Architecture:**
- The static site `web/` (no build step) is deployed on Vercel. It signs in with Supabase Auth and reads only my rows through RLS.
- Two Supabase Edge Functions (`plaid-link`, `plaid-sync`) hold the Plaid keys and talk to Plaid. pg_cron runs the sync daily.
- Pure money logic lives in `web/lib/` and is shared with the functions through a byte-identical copy in `supabase/functions/_shared/`.

**Tech Stack:**
- Supabase: Postgres, Auth, Edge Functions (Deno), pg_cron, pg_net, Vault
- Vercel static hosting
- Plaid Link (`https://cdn.plaid.com/link/v2/stable/link-initialize.js`) and the Plaid REST API
- `@supabase/supabase-js@2.49.4`, `@observablehq/plot@0.6.16` and `d3@7.9.0` from jsDelivr
- Tests: Node 22 `node --test`, with no npm dependencies

**Spec:** `docs/superpowers/specs/2026-11-20-finance-dashboard-design.md`. The visual reference is `docs/reference/preview.html`.

**Execution:** in this cloud session. Each **Phase** ends with a **CHECK-IN** with me, and the next phase waits for my go-ahead.

## Global Constraints

- **Supabase:** project `pnkrlpvpqakqlwymybpj`, reused. Never touch `dyoowadyyfjjiskvrnuw` (schooling).
- **Vercel:** team `team_Gu2TqoM4UtwpY1DNbC72I9Zl`, project `prj_hQQQO19aAJzh5hImpy4IzdId3oXK`, renamed to `finance-dashboard`. Never touch `schooling-dashboard`.
- **Tables:** every table has `user_id uuid not null default auth.uid()`, RLS enabled, and owner-only policies using `(select auth.uid())`. `plaid_items` has **no** policies, and all privileges on it are revoked from `anon` and `authenticated`.
- **Amounts:** stored as `numeric(12,2)` in Plaid's sign convention: **positive means money out**, negative means money in. Display formatting lives only in `web/lib/money.js`.
- **Secrets:** `PLAID_CLIENT_ID`, `PLAID_SECRET` and `PLAID_ENV` (`sandbox` or `production`) are Edge Function secrets that I set myself. The cron secret is generated in Postgres and stored in Vault as `plaid_cron_secret`. None of them is ever printed, logged or committed.
- **Logging:** functions log counts and status codes only. They never log tokens, amounts, merchant names or account numbers.
- **Plaid settings:** Link token `products: ["transactions"]`, `transactions: { days_requested: 730 }`, `country_codes: ["US"]`, `language: "en"`, and `user.client_user_id` set to my auth uid. Transactions sync requests `personal_finance_category_version: "v2"`.
- **CSP** (in `web/vercel.json`):
  - `script-src 'self' https://cdn.jsdelivr.net https://cdn.plaid.com`
  - `frame-src https://cdn.plaid.com`
  - `connect-src 'self' https://pnkrlpvpqakqlwymybpj.supabase.co https://production.plaid.com https://sandbox.plaid.com`
  - all other directives as now
- **Fixed copy, used verbatim:**
  - footer: "Figures come from your bank via Plaid and may lag a day or two. This dashboard shows patterns, not financial advice."
  - first-sync message: "Gathering your history…"
  - reconnect button: "Reconnect Grow"
  - rebuilt-balance label: "rebuilt from transactions"
- **Tests use invented data only.** SQL checks run in a DO block that always rolls back, ending with `raise exception 'ALL_CHECKS_PASSED'`.

## Review Focus

1. **A pending transaction posts:** Plaid removes the pending ID and adds a posted one. It's counted once, and pending is excluded from totals. (Tests in Tasks 4 and 6.)
2. **"Always for this merchant" when Plaid gives no `merchant_name`.** The rule key falls back to the normalised `name`, and the rule still matches later transactions. (Tests in Tasks 2 and 4.)
3. **Grow needs re-login during the nightly sync** (`ITEM_LOGIN_REQUIRED`). The item status becomes `login_required`, the sync ends cleanly with a logged error, and the header shows "Reconnect Grow". (Test in Task 6.)
4. **A first month, or a month with no income.** Charts show $0 rather than NaN or blank bars. The 3-month average uses whatever months exist and says so ("2-month average"). (Test in Task 4.)
5. **The first 24-month sync is large or not ready yet.** Paging continues while `has_more` is true. A `PRODUCT_NOT_READY` answer is logged as "Gathering your history…" without failing, and the next run picks it up. (Test in Task 6.)

---

## File Structure

```
web/vercel.json                 # CSP (+ Plaid), headers
web/index.html                  # dashboard
web/connect.html                # link / reconnect Grow, Refresh now
web/signin.html                 # kept
web/styles.css                  # kept tokens; health-only rules removed
web/app/config.js, supabase.js, guard.js, signin.js   # kept
web/app/connect.js              # Plaid Link flow
web/app/dashboard.js            # data load + render
web/app/api.js                  # callFunction(name, body) with session token
web/lib/money.js                # fmtUSD, fmtUSDWhole, categoryLabel
web/lib/rules.js                # effectiveCategory, merchantKey, isTransfer, monthTotals,
                                # categoryBreakdown, topMerchants, rebuildBalances
web/lib/plaid-map.js            # Plaid JSON → table rows (pure)
web/lib/sync-core.js            # runSync(plaidPost, db): paging, removals, balances, errors (pure)
web/lib/*.test.js, web/site.test.js
supabase/migrations/0002_finance.sql   # drop health objects; finance schema; RPCs
supabase/migrations/0003_cron.sql      # pg_cron + Vault secret
supabase/tests/0002_checks.sql
supabase/functions/_shared/plaid-map.js, rules.js, sync-core.js   # byte-identical copies of web/lib
supabase/functions/_shared/auth.ts      # requireCaller(req) → {userIds, via}
supabase/functions/_shared/plaid.ts     # plaidPost(path, body)
supabase/functions/plaid-link/index.ts
supabase/functions/plaid-sync/index.ts
README.md
```

---

## Phase A: Reset and foundation

### Task 1: Remove health code; money formatting

**Files:**
- Delete: `web/lib/units.js`, `web/lib/units.test.js`
- Create: `web/lib/money.js`, `web/lib/money.test.js`
- Modify: `web/index.html` (finance placeholder copy), `web/styles.css` (remove `.index-*`, `.comp`, `.energy-wrap`, `.calc`, `.bar-*` rules), `web/vercel.json` and `web/site.test.js` (Plaid CSP from Global Constraints)

**Interfaces:**
- Produces:
  - `fmtUSD(n): string`: `1234.5` gives `"$1,234.50"`, `-12` gives `"−$12.00"` (true minus sign), and `null` gives `"–"`
  - `fmtUSDWhole(n): string`: `1234.5` gives `"$1,235"`
  - `categoryLabel(code): string`: `"FOOD_AND_DRINK"` gives `"Food & drink"`, `"GENERAL_MERCHANDISE"` gives `"General merchandise"`, `"TRANSFER_IN"` gives `"Transfer in"`. Words are joined by spaces, `AND` becomes `&`, and the result is sentence case.

- [ ] **Step 1: Write the failing tests** in `money.test.js` for the values above. Also update `site.test.js` to assert the three CSP fragments from Global Constraints.
- [ ] **Step 2: Run `npm test`.** Expected: FAIL (money.js missing, CSP mismatch).
- [ ] **Step 3: Implement `money.js`,** update `vercel.json` and the copy, and delete the health files.
- [ ] **Step 4: Run `npm test`.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "chore: remove health code; money formatting; Plaid CSP"`.

### Task 2: Finance schema, RLS and RPCs

**Files:**
- Create: `supabase/migrations/0002_finance.sql`, `supabase/tests/0002_checks.sql`

**Interfaces:**
- Produces:
  - **Tables** (columns exactly as spec §6): `accounts`, `transactions`, `balances`, `category_rules`, `plaid_items`, `sync_log`
  - **Functions:**
    - `merchant_key(merchant text, name text) returns text`: lower-case, digits and `#*` stripped, whitespace collapsed. Uses `merchant` if it's not null, else `name`.
    - `set_category(p_transaction_id text, p_category text, p_always boolean) returns jsonb`. It's security invoker (RLS applies). With `p_always` false it sets `category_override` on that one row. With `p_always` true it upserts `category_rules(merchant_key, category)` for that transaction's merchant and returns `{"rule": true, "matched": <count of my transactions with that key>}`.
    - `connection_status() returns table(institution_name text, status text, updated_at timestamptz)`. It's **security definer** with `search_path = ''`, returns only the caller's rows from `plaid_items`, and is granted to `authenticated` only.
  - **Indexes:** `transactions(user_id, date)` and `transactions(user_id, account_id, date)`

- [ ] **Step 1: Write the failing checks** in `0002_checks.sql`:
  - `fin_two_users_isolated`: user A inserts an account and a transaction, and user B sees 0 rows
  - `fin_anon_sees_nothing`: 0 rows or permission denied on every table, and `connection_status()` is denied
  - `fin_token_unreadable`: insert a `plaid_items` row as postgres for user A, then as A `select access_token from plaid_items` raises insufficient_privilege, and `connection_status()` returns 1 row with no token column
  - `fin_rule_by_name_fallback`: a transaction with `merchant_name` null and `name` `'SQ *JOES COFFEE #123'`, then `set_category(id, 'FOOD_AND_DRINK', true)`, creates a rule with key `'sq joes coffee'` and returns `matched = 1` (Review Focus 2)
  - `fin_override_one`: `set_category(id, 'TRAVEL', false)` sets the override on that row only
- [ ] **Step 2: Run them with `execute_sql`** before the migration. Expected: fails because the tables don't exist.
- [ ] **Step 3: Write and apply `0002_finance.sql`.** It first drops the health objects: tables `daily`, `weight`, `activities`, `vo2max`, `profile`, `settings` and `sync_log`, and functions `upsert_*` and `_caller`. All are empty; verify with `count(*)` = 0 for each before dropping. Then it creates the finance schema and revokes all from `anon`.
- [ ] **Step 4: Run the checks.** Expected: `ALL_CHECKS_PASSED`. Then run `get_advisors(security)`. Expected: no ERROR-level findings.
- [ ] **Step 5: Commit** with `git commit -m "feat: finance schema with RLS, locked Plaid tokens, category RPC"`.

### Task 3: Rename, redeploy and sign-ups

**Files:**
- Modify: Vercel project settings (rename only)

- [ ] **Step 1: Rename the Vercel project** to `finance-dashboard` with `update_project`, then redeploy `web/` (file upload, production).
- [ ] **Step 2: Verify the deployment.**
  - the deployed file SHA1s match the local files
  - `curl -sI` on the new production URL shows the Plaid CSP
  - in headless Chromium, `/` redirects to `/signin` with no console errors
- [ ] **Step 3: Commit** any config change with `git commit -m "chore: finance-dashboard deploy"`, and push.

**CHECK-IN (Phase A):** I do the steps still pending from the health version, using the new address:
1. Set the Supabase **Site URL** and **Redirect URL**.
2. Create my account at `/signin?setup=1` and confirm the email.
3. Turn off **Allow new users to sign up**.

- **Acceptance:** I can sign in, and a sign-up attempt made from here with the publishable key is refused.

---

## Phase B: Plaid connection (Sandbox first)

### Task 4: Pure money logic

**Files:**
- Create: `web/lib/rules.js`, `web/lib/rules.test.js`, `web/lib/plaid-map.js`, `web/lib/plaid-map.test.js`, `supabase/functions/_shared/rules.js`, `supabase/functions/_shared/plaid-map.js` (copies)

**Interfaces:**
- Produces in `rules.js`:
  - `merchantKey(merchant, name) → string`, the same algorithm as the SQL `merchant_key`
  - `effectiveCategory(tx, rulesByKey) → string`, in this order: override → rule → `pfc_primary`
  - `isTransfer(tx, allTx, rulesByKey) → boolean`: true for the TRANSFER_IN/OUT categories, or for a same-day opposite-amount pair on two different `account_id`s
  - `monthTotals(txs, rulesByKey) → [{month: "2026-03", income, spending, net}]`: pending and transfers excluded, refunds reduce spending, every month in range present with 0s
  - `categoryBreakdown(txs, rulesByKey, month) → [{category, amount, avg, avgMonths}]`, sorted by amount descending, where `avg` is over up to 3 prior months that have data
  - `topMerchants(txs, rulesByKey, month, n = 10) → [{merchant, amount, count}]`
  - `rebuildBalances(anchors: [{account_id, date, balance}], txs) → [{account_id, date, balance, source: "rebuilt"}]`: walks backwards from each account's earliest real balance to its earliest transaction, ignoring pending ones
- Produces in `plaid-map.js`:
  - `mapTransaction(plaidTx) → row`, with these columns: `transaction_id`, `account_id`, `date`, `authorized_date`, `amount`, `merchant_name`, `name`, `pfc_primary`, `pfc_detailed`, `pending`
  - `mapAccount(plaidAcct) → row`

- [ ] **Step 1: Write failing tests:**
  - `rebuild_worked_example`: an anchor of $1,000.00 on 2026-03-10 with transactions of +50.00 and −200.00 on that day gives $850.00 on 2026-03-09
  - `pending_excluded_from_totals`, and `pending_then_posted_counted_once` (the pending row is removed and the posted one added; Review Focus 1)
  - `refund_reduces_category`
  - `transfer_pair_detected`
  - `income_only_INCOME_category`
  - `month_with_no_income_is_zero` and `avg_uses_available_months` (`avgMonths === 2`; Review Focus 4)
  - `effective_category_order`
  - `merchant_key_fallback_to_name` gives `"sq joes coffee"` (Review Focus 2)
  - `map_transaction_v2_fields`, using a fake Plaid v2 transaction object
  - `shared_copies_identical`: each `supabase/functions/_shared/*.js` file is byte-equal to its `web/lib/` counterpart
- [ ] **Step 2: Run `npm test`.** Expected: FAIL.
- [ ] **Step 3: Implement both modules and copy them** into `_shared/`.
- [ ] **Step 4: Run `npm test`.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: money rules and Plaid mapping with worked-example tests"`.

### Task 5: `plaid-link` function

**Files:**
- Create: `supabase/functions/_shared/auth.ts`, `supabase/functions/_shared/plaid.ts`, `supabase/functions/plaid-link/index.ts`

**Interfaces:**
- Produces:
  - `POST /functions/v1/plaid-link` with body `{action: "create"}`, returning `{link_token}`. It uses update mode when my item's status is `login_required`.
  - `POST /functions/v1/plaid-link` with body `{action: "exchange", public_token, institution_name}`, returning `{ok: true}`. It stores `access_token` and `item_id` in `plaid_items`.
  - `requireCaller(req)` returns `{userIds: [uid], via: "user"}` from a valid user JWT (`auth.getUser`), or `{userIds: <all ids in plaid_items>, via: "cron"}` when `x-cron-secret` matches Vault. It throws a 401 otherwise.
  - `{action: "sandbox_reset"}` calls `/sandbox/item/reset_login` on my item, and `{action: "remove_test_bank"}` calls `/item/remove` and deletes my `plaid_items`, `accounts`, `transactions` and `balances` rows. **Both work only when `PLAID_ENV=sandbox`**, and return 403 otherwise.
  - The function is deployed with `verify_jwt: false`, because it checks auth itself.

- [ ] **Step 0 (me):**
  1. Create a free Plaid account (Trial plan).
  2. In Supabase → Edge Functions → Secrets, set `PLAID_CLIENT_ID` and `PLAID_SECRET` (the **Sandbox** secret), and set `PLAID_ENV=sandbox`.
- [ ] **Step 1: Deploy a stub** that returns 501, then run the failing checks with `curl`:
  - no auth gives 401
  - the publishable key only gives 401
  - a wrong `x-cron-secret` gives 401
- [ ] **Step 2: Implement it, deploy it,** and re-run the checks. Expected: 401, 401, 401.
- [ ] **Step 3: Commit** with `git commit -m "feat: plaid-link function with auth guard"`.

### Task 6: `plaid-sync` function and schedule

**Files:**
- Create: `supabase/functions/plaid-sync/index.ts`, `supabase/migrations/0003_cron.sql`

**Interfaces:**
- Produces: `POST /functions/v1/plaid-sync` (auth as in Task 5), returning `{added, modified, removed, status}`. For each item it:
  1. Loops `/transactions/sync` from the stored cursor while `has_more` is true.
  2. Maps rows with `plaid-map.js` and upserts accounts and transactions with the service role.
  3. Deletes the removed transaction IDs and saves the new cursor.
  4. Calls `/accounts/balance/get` and upserts today's `balances` rows (`source = 'plaid'`).
  5. When no `rebuilt` rows exist yet, computes `rebuildBalances` and inserts them.
  6. Writes `sync_log`.
- On errors:
  - `ITEM_LOGIN_REQUIRED` sets `status = 'login_required'` and logs the error, and the response is still 200
  - `PRODUCT_NOT_READY` logs "Gathering your history…"
- `0003_cron.sql` creates the Vault secret `plaid_cron_secret` (`gen_random_uuid()`) and the job `cron.schedule('plaid-sync-daily', '17 6 * * *', …)`, which calls `net.http_post` with the `x-cron-secret` header.

- [ ] **Step 1: Write the failing tests** in `web/lib/sync-core.test.js` for a pure `runSync(plaidPost, db)` core in `web/lib/sync-core.js`, with fake `plaidPost` and `db` objects (copied to `_shared/`):
  - `pages_until_has_more_false` (Review Focus 5)
  - `removed_ids_deleted`
  - `login_required_sets_status_and_returns_ok` (Review Focus 3)
  - `product_not_ready_logged_not_thrown` (Review Focus 5)
  - `cursor_saved_after_success_only`
- [ ] **Step 2: Run `npm test`.** Expected: FAIL.
- [ ] **Step 3: Implement `sync-core.js`, copy it to `_shared/`** (covered by `shared_copies_identical`), and write the thin `index.ts` that wires the real Plaid and Supabase into it. Deploy, then apply `0003_cron.sql`.
- [ ] **Step 4: Run `npm test`** (expect PASS) and the `curl` 401 checks. Confirm `cron.job` lists `plaid-sync-daily`.
- [ ] **Step 5: Commit** with `git commit -m "feat: plaid-sync with paging, removals, balances, daily schedule"`.

### Task 7: Connect page and Refresh

**Files:**
- Create: `web/connect.html`, `web/app/connect.js`, `web/app/api.js`
- Modify: `web/index.html` (nav link "Connect")

**Interfaces:**
- Produces: `callFunction(name, body) → Promise<object>` in `api.js`. It sends `Authorization: Bearer <session access token>`, and throws an `Error` with a plain-words message on any non-2xx response.

- [ ] **Step 1: Extend `site.test.js`:**
  - `connect.html` loads `link-initialize.js` from `https://cdn.plaid.com/link/v2/stable/` and loads `app/guard.js`
  - no inline scripts
- [ ] **Step 2: Run `npm test`.** Expected: FAIL.
- [ ] **Step 3: Implement the connect page.**
  - It shows `connection_status()`.
  - The **"Connect Grow"** button (or **"Reconnect Grow"** when status is `login_required`) runs `create`, then `Plaid.create({token, onSuccess})`, then `exchange`, then `plaid-sync`.
  - The **"Refresh now"** button calls `plaid-sync` and shows the counts.

  Then redeploy.
- [ ] **Step 4: Run `npm test`** (expect PASS) and the headless check that `/connect` redirects to sign-in when signed out.
- [ ] **Step 5: Commit** with `git commit -m "feat: connect page with Plaid Link and refresh"`.

**CHECK-IN (Phase B, Sandbox):**
1. I connect Plaid's test bank (`user_good` / `pass_good`) at `/connect`.
2. Verify, printing counts only:
   - transactions and accounts arrived
   - pressing Refresh again adds 0
   - `select access_token from plaid_items` as my user is denied
3. Simulate re-login with Plaid's `/sandbox/item/reset_login`, called from a one-off function mode `{action: "sandbox_reset"}` that works only when `PLAID_ENV=sandbox`. Then confirm "Reconnect Grow" appears and reconnecting works.

---

## Phase C: Dashboard

### Task 8: Dashboard page and recategorize

**Files:**
- Modify: `web/index.html`
- Create: `web/app/dashboard.js`, `web/lib/shape.js`, `web/lib/shape.test.js`

**Interfaces:**
- Consumes: `rules.js`, `money.js`, `api.js`, `connection_status()`, `set_category`
- Produces: `loadAll(supabase) → {accounts, txs, balances, rules, status, lastSync}`. It pages PostgREST 1,000 rows at a time. `shape.js` holds `rulesIndex(rules)` and `balanceSeries(balances) → [{date, total, source}]`, which sums accounts per date.

- [ ] **Step 1: Write failing tests:**
  - `balance_series_sums_accounts`
  - `balance_series_marks_rebuilt_segment`
  - `rules_index_by_key`
- [ ] **Step 2: Run `npm test`.** Expected: FAIL.
- [ ] **Step 3: Implement the page, in the order of spec §8:**
  1. **Header:** month picker, last sync, "Refresh now", and the connection status or "Reconnect Grow".
  2. **This month:**
     - category bar list with 3-month-average markers and the difference in words
     - top 10 merchants
     - total spending and income
  3. **In vs out:** 12 months of income and spending bars, plus a separate net chart.
  4. **Total balance:** a solid line for `plaid` points and a dashed line for `rebuilt`, labelled "rebuilt from transactions".
  5. **Transactions:**
     - search and filters
     - tapping a category opens a dialog with "Just this one" and "Always for [merchant]", which calls `set_category` and re-renders
  6. **Footer** with the fixed copy.

  Charts follow the dataviz rules: one axis per chart, a legend for 2 or more series, tooltips, and 4px rounded bar ends. Show "Gathering your history…" while there are no transactions and `sync_log` holds no success yet.
- [ ] **Step 4: Run `npm test`, redeploy, and run the headless smoke test** (signed out redirects; no console errors on `/signin`).
- [ ] **Step 5: Commit** with `git commit -m "feat: finance dashboard with recategorize"`.

**CHECK-IN (Phase C):** I review the dashboard on the Sandbox data, on laptop and phone.
- **Acceptance:**
  - every section renders
  - recategorizing works and "always" also updates past transactions
  - the totals look right against the transaction list

---

## Phase D: Go live

### Task 9: Production, security gates, README

**Files:**
- Modify: `README.md`, and the PR description

- [ ] **Step 0 (me), in this order:**
  1. At `/connect`, press **"Remove test bank"**. This is `remove_test_bank`, shown only while in sandbox.
  2. In Supabase secrets, set `PLAID_SECRET` to the **Production** secret and `PLAID_ENV=production`.
  3. At `/connect`, connect **Grow Financial**.
- [ ] **Step 1: Run every security gate from spec §9** and record the evidence in the ledger:
  1. the advisors report
  2. anon reads return 0 rows or are denied
  3. the token is unreadable to my user (database check)
  4. a sign-up attempt fails
  5. a `git grep` for secrets finds none, and the Vercel env list is reviewed
  6. both functions return 401 without auth
  7. the CSP header is present
- [ ] **Step 2: Write the README.** Sections:
  - what it is
  - where data lives (the table from the spec)
  - connecting and reconnecting Grow
  - how the daily sync works
  - recategorizing
  - what to do if Supabase pauses the project, or Plaid asks to re-login
- [ ] **Step 3: Rewrite the PR description** for the finance dashboard (with my OK). Commit and push.

**CHECK-IN (Phase D, final):**
- **Acceptance:**
  - my real Grow transactions and balances show up
  - the next morning's automatic sync appears in the header
  - "Refresh now" works
