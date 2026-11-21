# Personal Finance Dashboard: Design Spec

- **Date:** 2026-11-20
- **Status:** Draft for review
- **Replaces:** the health dashboard project, dropped on 2026-11-20. The health specs and plans stay in the repo's history only.
- **Visual reference:** the calm style of the health preview (`docs/reference/preview.html`): same tokens, type and chart conventions.

## 1. Purpose

A private dashboard that shows where my money goes. It's hosted, with sign-in, on my phone and laptop. It answers three questions:

1. **Where did my money go this month?** Spending by category, and the biggest merchants.
2. **Am I spending less than I earn?** Money in versus money out, month by month.
3. **Is my total balance growing?** Checking plus savings at Grow, over time.

It shows facts and trends only. It never gives financial advice or recommendations.

## 2. Scope

**In scope**

- My Grow Financial Federal Credit Union checking and savings accounts, connected automatically through **Plaid**.
- Up to 24 months of history on first connection, then a daily sync plus a "Refresh now" button.
- Plaid's categories, plus my corrections. A correction can become a rule for that merchant.
- One user, US dollars only.

**Out of scope for now:** Fidelity and any investment accounts, credit cards, budgets, subscription tracking, AI categorisation, and sharing with anyone.

**Possible later additions:** Fidelity, via a monthly positions file or a future aggregator connection; budgets.

## 3. Data source: Plaid (Trial plan)

- **Plan:** Plaid's free **Trial** plan, for US developers who created a Plaid team on or after 2026-04-15.
  - It allows 10 bank connections ("Items"). This project uses **1**.
  - Removing an Item doesn't free its slot. Re-authenticating an existing connection ("update mode") doesn't use a new slot.
  - It includes the Transactions and Balance products.
- **Connecting:** the browser opens **Plaid Link**, Plaid's own window loaded from `cdn.plaid.com`, and I log in to Grow there.
  - My Grow password goes only to Plaid. It never touches my site, Supabase or the repo.
  - Link returns a one-time `public_token`. A server-side function exchanges it for an `access_token`.
- **History:** `transactions.days_requested = 730` is set when creating the Link token. This only takes effect at first connection.
- **Category taxonomy:** Plaid's personal finance categories v2. Each transaction has a primary category (for example `FOOD_AND_DRINK`, `TRANSFER_IN`, `INCOME`) and a detailed one.
- **Syncing:** `/transactions/sync` with a stored cursor. Each call returns `added`, `modified` and `removed` since the last call, so syncing is idempotent and a re-run creates no duplicates.
- **Balances:** `/accounts/balance/get` once per sync. It gives each account's current balance, saved as that day's snapshot.
- **Keys:** `PLAID_CLIENT_ID`, `PLAID_SECRET` and `PLAID_ENV` (`sandbox` while building, then `production`) are stored as **Supabase Edge Function secrets**. I enter them in the Supabase dashboard; they're never in chat, the repo or Vercel.

## 4. What is stored where

| Place | What it holds | Who can read it |
|---|---|---|
| **Supabase** (existing project `pnkrlpvpqakqlwymybpj`, reused) | Accounts (name, type, last 4 digits), transactions (date, amount, merchant, category), daily balances, my category rules and corrections, sync log, and my login. The Plaid `access_token` is in a table that **no user role can read**. | Only my signed-in account (row-level security). The access token is readable only by the server-side functions. |
| **Supabase Edge Function secrets** | Plaid client ID, Plaid secret and environment | Only the functions |
| **Plaid** | A copy of the Grow data it retrieves, under Plaid's privacy policy. This is inherent to any automatic connection. | Plaid |
| **Vercel** (project renamed to `finance-dashboard`) | Website files only: HTML, JS, CSS, the Supabase URL and the publishable key | Public page shell, no financial data |
| **GitHub** | Code, docs, fake test fixtures | Repo collaborators |

Financial data flows Grow → Plaid → Supabase, and Supabase ↔ my browser. It never passes through Vercel.

## 5. Architecture

```
Browser (web/, static) ──login + RLS reads/writes──► Supabase Postgres
   │  Plaid Link (cdn.plaid.com)                         ▲
   │     └─public_token─► Edge Fn plaid-link ──────────┤ (service role)
   └─"Refresh now"──────► Edge Fn plaid-sync ◄── pg_cron daily 06:17 UTC
                                 │
                                 └──► Plaid API (transactions/sync, accounts/balance/get)
```

**Reused from the health work, already built and tested:**
- the static site in `web/`
- sign-in and the session guard
- the CSP approach
- the Vercel deploy
- the Supabase project
- the RLS pattern
- the security gates

**Edge Function `plaid-link`:**
- `create` returns a Link token. It uses update mode when a connection needs re-authentication.
- `exchange` swaps the `public_token` for an access token and stores it.
- Both require my session.

**Edge Function `plaid-sync`:**
1. Runs `/transactions/sync` until `has_more` is false.
2. Upserts the added and modified transactions, and deletes the removed ones.
3. Saves the cursor.
4. Fetches balances and stores today's snapshot.
5. Writes the sync log.

It's authorised by my session ("Refresh now"), or by a cron secret held in Supabase Vault (the daily run).

**Shared logic** lives in `web/lib/` as pure ES modules: transfer detection, rule application, monthly aggregation and balance reconstruction. It's used by the browser and tested with `node --test`.

## 6. Data model (Postgres; every table has `user_id`, RLS owner-only)

- **`accounts`**: `account_id` (Plaid), `name`, `official_name`, `mask` (last 4), `type`, `subtype`, `current_balance`, `available_balance`, `updated_at`
- **`transactions`**:
  - Columns: `transaction_id` (Plaid, primary key with `user_id`), `account_id`, `date`, `authorized_date`, `amount` numeric(12,2), `merchant_name`, `name`, `pfc_primary`, `pfc_detailed`, `pending`, `category_override`, `note`, `updated_at`
  - **Sign rule:** `amount` keeps Plaid's convention, where **positive means money out** and negative means money in. The UI converts it for display.
- **`balances`**: `account_id`, `date`, `balance`, `source` (`plaid` for real snapshots, `rebuilt` for reconstructed history). Unique on (`user_id`, `account_id`, `date`).
- **`category_rules`**: `merchant_key` (normalised merchant name), `category`, `created_at`. Unique on (`user_id`, `merchant_key`).
- **`plaid_items`**: `item_id`, `access_token`, `cursor`, `institution_name`, `status` (`ok` or `login_required`), `updated_at`.
  - RLS is enabled with **no policies**, and select/insert/update are revoked from `authenticated` and `anon`. Only the service role, inside the functions, can touch it.
  - A view `connection_status` exposes only `institution_name`, `status` and `updated_at` to me.
- **`sync_log`**: `ran_at`, `ok`, `added`, `modified`, `removed`, `error`
- **Removed:** the health tables and functions (`daily`, `weight`, `activities`, `vo2max`, `profile`, `settings`, `sync_log`, `upsert_*`, `_caller`). They're dropped in the first build phase; they contain no data.

## 7. Money rules

1. **Effective category** = `category_override` if set → else a matching `category_rules` entry for the merchant → else Plaid's `pfc_primary`. It's shown in plain words, for example `FOOD_AND_DRINK` → "Food & drink".
2. **Transfers** are excluded from both spending and income. A transaction counts as a transfer when its effective category is `TRANSFER_IN` or `TRANSFER_OUT`, or when a same-day pair of opposite amounts moves between two of my own accounts.
3. **Spending** is outflows (amount > 0) that aren't transfers, grouped by effective category.
4. **Income** is non-transfer inflows (amount < 0) whose effective category is `INCOME`. Any other non-transfer inflow is a **refund**, and it reduces its category's spending for that month.
5. **Pending** transactions are shown in the list, marked "pending", but **left out of monthly totals** until they post. When Plaid posts one it reports a change, and the sync replaces it.
6. **Months** follow the transaction `date` (Plaid's posted date), by calendar month.
7. **Balance history:**
   - From the first connection onwards, real daily snapshots.
   - Before that, rebuilt backwards from the earliest real balance, since balance on the day before = balance on that day + that day's amounts (Plaid sign), per account.
   - Rebuilt points are stored with `source = 'rebuilt'`, and the chart labels them "rebuilt from transactions". Pending transactions are ignored in the rebuild.
8. **Amounts** are shown as US dollars with cents in tables, and whole dollars on chart axes.

## 8. Dashboard layout

This is one scrolling page in the health preview's style, with light and dark mode, tooltips on every chart, and a layout that works at phone width.

1. **Header:**
   - month picker, defaulting to the current month
   - "Last synced …"
   - **Refresh now** button
   - connection status ("Grow connected" or "Reconnect Grow")
2. **This month:**
   - a ranked bar list of spending by category, each with a marker for my 3-month average and the difference in words ("$84 more than usual")
   - beside it, the **top 10 merchants**
   - the month's total spending and income as two headline numbers
3. **In vs out:**
   - 12 months of income and spending bars on one shared dollar axis
   - below it, a separate small bar chart of each month's net ("saved" or "overspent")
4. **Total balance:** checking plus savings over 12 months (or "All"). Real snapshots are a solid line; the rebuilt history is a dashed line, labelled.
5. **Transactions:**
   - a searchable, filterable list (by month, category, account)
   - tapping the category opens a picker with "Just this one" or "Always for [merchant]"
   - choosing "Always" writes a `category_rules` row, which applies to past and future transactions
6. **Footer:** "Figures come from your bank via Plaid and may lag a day or two. This dashboard shows patterns, not financial advice."

**Pages:**
- `/` the dashboard
- `/connect` link Grow, or reconnect it
- `/signin`

## 9. Security gates (each phase must keep these passing)

1. **RLS on every table.** Supabase security advisors show no errors.
2. **The publishable key can read nothing,** including from `transactions` and `plaid_items`. The `connection_status` view and the RPCs are also unreachable with it.
3. **A signed-in user can't read `plaid_items`** (the access token), verified with a database check.
4. **Sign-ups are disabled** after my account exists.
5. **No Plaid secret, access token, service-role key or financial data** in the repo, Vercel or logs. Functions never log tokens or amounts.
6. **Both Edge Functions return 401** to anyone but my session or the cron secret.
7. **The CSP** allows only:
   - scripts from self, `cdn.jsdelivr.net` and `https://cdn.plaid.com/link/v2/stable/link-initialize.js`
   - frames from `https://cdn.plaid.com`
   - connections to self, my Supabase project and `https://production.plaid.com`

## 10. Error handling

- **`ITEM_LOGIN_REQUIRED`**, or another Item error from Plaid, sets `status = 'login_required'`. The header then shows **Reconnect Grow**, which opens Link in update mode.
- **Plaid rate limits or network errors** are logged, and the sync retries on the next run. The dashboard header shows the last successful sync and the error in plain words.
- **First sync:** Plaid can take a while to gather 24 months of history, so the page shows "Gathering your history…" until the first sync completes.
- **No data:** sections show "No transactions yet".

## 11. Testing

- **Unit tests** (`node --test`, fake transactions):
  - effective category order
  - transfer detection, including the same-day opposite pair
  - refunds reduce spending
  - pending excluded from totals
  - monthly in/out/net
  - 3-month category average
  - balance rebuild (worked example below)
  - top merchants
  - dollar formatting
- **Database checks** (rolled-back SQL):
  - RLS isolation between two users
  - anon gets nothing
  - a signed-in user can't read `plaid_items`
  - rules apply to past transactions
- **Plaid Sandbox end to end,** before connecting the real Grow account: link the test bank (`user_good` / `pass_good`), sync, see transactions and balances, re-run the sync and see no duplicates, then simulate `ITEM_LOGIN_REQUIRED` and see "Reconnect Grow".
- **Balance rebuild worked example:** the real balance on 2026-03-10 is $1,000.00. On 2026-03-10 there's $50.00 out (amount +50.00) and $200.00 in (amount −200.00). So the rebuilt balance on 2026-03-09 = 1000 + 50 − 200 = **$850.00**.

## 12. Cleanup and reuse

- **Supabase:** drop the health tables and functions (all empty) in the first migration of this project. I may rename the project to `finance-dashboard` in the Supabase dashboard; that's optional and cosmetic.
- **Vercel:** rename project `health-dashboard` to `finance-dashboard`, and redeploy. The production address changes, and the Supabase Site URL and Redirect URL get updated to match.
- **Repo:** the health-specific UI (preview reference, health styles) is replaced. The shared tokens, sign-in, guard and CSP pattern are kept. The PR description gets rewritten for the finance dashboard.

## 13. Cost

$0. Plaid Trial uses 1 of 10 connections; Supabase and Vercel stay on their free plans.

## 14. To confirm during the build

1. **Grow connects through Plaid Link in production** and returns checking and savings, with 24 months of history (or whatever Grow provides).
2. **Plaid's v2 category names on my real data,** to tune the plain-word category labels.
3. **The exact Plaid Link CSP lines,** checked against Plaid's live docs when the connect page is built.
