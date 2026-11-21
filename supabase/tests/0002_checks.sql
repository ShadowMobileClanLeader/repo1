-- Database checks for 0002_finance. One DO block that ALWAYS rolls back:
-- success ends with 'ALL_CHECKS_PASSED'; any failure raises 'CHECK FAILED: …'. Invented data only.
do $$
declare
  a uuid := '00000000-0000-4000-8000-0000000000fa';
  b uuid := '00000000-0000-4000-8000-0000000000fb';
  n int; res jsonb; t text;
begin
  insert into auth.users (id, aud, role, email) values
    (a, 'authenticated', 'authenticated', 'fin-check-a@example.invalid'),
    (b, 'authenticated', 'authenticated', 'fin-check-b@example.invalid');
  -- the access token is written by the server side only
  insert into public.plaid_items (user_id, item_id, access_token, institution_name, status)
    values (a, 'item-fake', 'access-sandbox-fake-token', 'Fake Bank', 'ok');

  -- user A writes their own rows
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  insert into public.accounts (account_id, name, mask, type, subtype) values ('acc-1', 'Checking', '0001', 'depository', 'checking');
  insert into public.transactions (transaction_id, account_id, date, amount, merchant_name, name, pfc_primary, pending)
    values ('tx-1', 'acc-1', '2026-03-10', 4.50, null, 'SQ *JOES COFFEE #123', 'FOOD_AND_DRINK', false),
           ('tx-2', 'acc-1', '2026-03-11', 4.75, null, 'SQ *JOES COFFEE #456', 'GENERAL_MERCHANDISE', false),
           ('tx-3', 'acc-1', '2026-03-12', 900.00, 'Airline', 'AIRLINE', 'GENERAL_MERCHANDISE', false);

  -- fin_token_unreadable
  begin
    select access_token into t from public.plaid_items limit 1;
    raise exception 'CHECK FAILED: fin_token_unreadable, user could read access_token';
  exception when insufficient_privilege then null;
  end;
  select count(*) into n from public.connection_status();
  if n <> 1 then raise exception 'CHECK FAILED: connection_status returned % rows', n; end if;

  -- fin_rule_by_name_fallback (merchant_name is null → key from name)
  if public.merchant_key(null, 'SQ *JOES COFFEE #123') <> 'sq joes coffee' then
    raise exception 'CHECK FAILED: merchant_key gave %', public.merchant_key(null, 'SQ *JOES COFFEE #123');
  end if;
  res := public.set_category('tx-1', 'FOOD_AND_DRINK', true);
  if (res ->> 'rule')::boolean is not true or (res ->> 'matched')::int <> 2 then
    raise exception 'CHECK FAILED: fin_rule_by_name_fallback %', res;
  end if;
  select count(*) into n from public.category_rules where merchant_key = 'sq joes coffee' and category = 'FOOD_AND_DRINK';
  if n <> 1 then raise exception 'CHECK FAILED: rule row missing'; end if;

  -- fin_override_one
  perform public.set_category('tx-3', 'TRAVEL', false);
  select count(*) into n from public.transactions where category_override = 'TRAVEL';
  if n <> 1 then raise exception 'CHECK FAILED: fin_override_one, % rows overridden', n; end if;

  -- fin_two_users_isolated
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from (
    select 1 from public.accounts union all select 1 from public.transactions union all select 1 from public.balances
    union all select 1 from public.category_rules union all select 1 from public.sync_log) x;
  if n <> 0 then raise exception 'CHECK FAILED: fin_two_users_isolated, B sees % rows', n; end if;
  select count(*) into n from public.connection_status();
  if n <> 0 then raise exception 'CHECK FAILED: B sees A''s connection'; end if;
  begin
    perform public.set_category('tx-1', 'TRAVEL', false);
    raise exception 'CHECK FAILED: B could recategorize A''s transaction';
  exception when no_data_found then null;
  end;

  -- fin_anon_sees_nothing
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  foreach t in array array['accounts', 'transactions', 'balances', 'category_rules', 'plaid_items', 'sync_log'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      if n <> 0 then raise exception 'CHECK FAILED: anon sees % rows in %', n, t; end if;
    exception when insufficient_privilege then null;
    end;
  end loop;
  begin
    perform public.connection_status();
    raise exception 'CHECK FAILED: anon could call connection_status';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.set_category('tx-1', 'TRAVEL', false);
    raise exception 'CHECK FAILED: anon could call set_category';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  raise exception 'ALL_CHECKS_PASSED';
end $$;
