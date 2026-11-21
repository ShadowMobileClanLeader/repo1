-- Personal finance dashboard schema. Replaces the (empty) health schema from 0001.
-- Amounts keep Plaid's sign: positive = money out, negative = money in.

------------------------------------------------------------------------------
-- Remove the health objects (all verified empty before this migration ran)
------------------------------------------------------------------------------
drop function if exists public.upsert_daily(jsonb, uuid);
drop function if exists public.upsert_weight(jsonb, uuid);
drop function if exists public.upsert_activities(jsonb, uuid);
drop function if exists public.upsert_vo2max(jsonb, uuid);
drop function if exists public.upsert_profile(jsonb, uuid);
drop function if exists public._caller(uuid);
drop table if exists public.daily, public.weight, public.activities, public.vo2max,
  public.profile, public.settings, public.sync_log;

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------
create table public.accounts (
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  account_id        text not null,
  name              text,
  official_name     text,
  mask              text,
  type              text,
  subtype           text,
  current_balance   numeric(12,2),
  available_balance numeric(12,2),
  updated_at        timestamptz not null default now(),
  primary key (user_id, account_id)
);

create table public.transactions (
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  transaction_id    text not null,
  account_id        text not null,
  date              date not null,
  authorized_date   date,
  amount            numeric(12,2) not null,
  merchant_name     text,
  name              text,
  pfc_primary       text,
  pfc_detailed      text,
  pending           boolean not null default false,
  category_override text,
  note              text,
  updated_at        timestamptz not null default now(),
  primary key (user_id, transaction_id)
);
create index transactions_user_date on public.transactions (user_id, date);
create index transactions_user_account_date on public.transactions (user_id, account_id, date);

create table public.balances (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  account_id text not null,
  date       date not null,
  balance    numeric(12,2) not null,
  source     text not null check (source in ('plaid', 'rebuilt')),
  primary key (user_id, account_id, date)
);

create table public.category_rules (
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  merchant_key text not null,
  category     text not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, merchant_key)
);

-- Holds the Plaid access token: no user-facing policies, no user grants. Server side only.
create table public.plaid_items (
  user_id          uuid not null references auth.users (id) on delete cascade,
  item_id          text not null,
  access_token     text not null,
  cursor           text,
  institution_name text,
  status           text not null default 'ok' check (status in ('ok', 'login_required')),
  updated_at       timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table public.sync_log (
  id       bigint generated always as identity primary key,
  user_id  uuid not null default auth.uid() references auth.users (id) on delete cascade,
  ran_at   timestamptz not null default now(),
  ok       boolean not null,
  added    integer not null default 0,
  modified integer not null default 0,
  removed  integer not null default 0,
  error    text
);
create index sync_log_user_ran_at on public.sync_log (user_id, ran_at desc);

------------------------------------------------------------------------------
-- Row-level security
------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['accounts', 'transactions', 'balances', 'category_rules'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))', t || '_select_own', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (user_id = (select auth.uid()))', t || '_insert_own', t);
    execute format('create policy %I on public.%I for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t || '_update_own', t);
    execute format('create policy %I on public.%I for delete to authenticated using (user_id = (select auth.uid()))', t || '_delete_own', t);
  end loop;
end $$;

alter table public.sync_log enable row level security;
create policy sync_log_select_own on public.sync_log for select to authenticated using (user_id = (select auth.uid()));

alter table public.plaid_items enable row level security;  -- and no policies at all
revoke all on public.plaid_items from anon, authenticated;

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

------------------------------------------------------------------------------
-- Functions
------------------------------------------------------------------------------
-- 'SQ *JOES COFFEE #123' → 'sq joes coffee'. Same algorithm as merchantKey() in web/lib/rules.js.
create or replace function public.merchant_key(merchant text, name text)
returns text
language sql immutable set search_path = ''
as $$
  select btrim(regexp_replace(regexp_replace(lower(coalesce(nullif(btrim(merchant), ''), name, '')),
         '[0-9#*]', '', 'g'), '\s+', ' ', 'g'));
$$;

-- Recategorize one transaction, or (p_always) every transaction from that merchant via a rule.
create or replace function public.set_category(p_transaction_id text, p_category text, p_always boolean)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  k text;
  matched int;
begin
  if uid is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if coalesce(btrim(p_category), '') = '' then raise exception 'Category is required'; end if;
  select public.merchant_key(t.merchant_name, t.name) into k
    from public.transactions t where t.user_id = uid and t.transaction_id = p_transaction_id;
  if not found then raise exception 'Transaction not found' using errcode = 'P0002'; end if;

  if not p_always then
    update public.transactions set category_override = p_category, updated_at = now()
      where user_id = uid and transaction_id = p_transaction_id;
    return jsonb_build_object('rule', false, 'matched', 1);
  end if;

  insert into public.category_rules (user_id, merchant_key, category) values (uid, k, p_category)
    on conflict (user_id, merchant_key) do update set category = excluded.category;
  -- a one-off override on this transaction would hide the new rule
  update public.transactions set category_override = null, updated_at = now()
    where user_id = uid and transaction_id = p_transaction_id;
  select count(*) into matched from public.transactions t
    where t.user_id = uid and public.merchant_key(t.merchant_name, t.name) = k;
  return jsonb_build_object('rule', true, 'matched', matched);
end $$;

-- What the page may know about the bank connection — never the token.
create or replace function public.connection_status()
returns table (institution_name text, status text, updated_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select p.institution_name, p.status, p.updated_at
  from public.plaid_items p
  where p.user_id = auth.uid();
$$;

revoke execute on function public.merchant_key(text, text) from public, anon;
revoke execute on function public.set_category(text, text, boolean) from public, anon;
revoke execute on function public.connection_status() from public, anon;
grant execute on function public.merchant_key(text, text) to authenticated, service_role;
grant execute on function public.set_category(text, text, boolean) to authenticated, service_role;
grant execute on function public.connection_status() to authenticated;
