-- Database checks for 0001_init. Runs as one DO block and ALWAYS rolls back:
-- success ends with the exception text 'ALL_CHECKS_PASSED'; any failure raises 'CHECK FAILED: …'.
-- Uses only invented test users and values.
do $$
declare
  a uuid := '00000000-0000-4000-8000-00000000000a';
  b uuid := '00000000-0000-4000-8000-00000000000b';
  res jsonb; n int; v numeric; f boolean;
begin
  insert into auth.users (id, aud, role, email) values
    (a, 'authenticated', 'authenticated', 'check-a@example.invalid'),
    (b, 'authenticated', 'authenticated', 'check-b@example.invalid');

  -- db_two_users_isolated + db_upsert_idempotent (user A)
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  res := public.upsert_daily('[{"date":"2026-01-01","steps":8000,"resting_hr":52},{"date":"2026-01-02","steps":9000,"resting_hr":51},{"date":"2026-01-03","steps":7000,"resting_hr":53}]');
  if res <> '{"inserted":3,"updated":0,"unchanged":0}'::jsonb then raise exception 'CHECK FAILED: first upsert %', res; end if;
  res := public.upsert_daily('[{"date":"2026-01-01","steps":8000,"resting_hr":52},{"date":"2026-01-02","steps":9000,"resting_hr":51},{"date":"2026-01-03","steps":7000,"resting_hr":53}]');
  if res <> '{"inserted":0,"updated":0,"unchanged":3}'::jsonb then raise exception 'CHECK FAILED: db_upsert_idempotent %', res; end if;

  -- db_upsert_never_nulls
  res := public.upsert_daily('[{"date":"2026-01-01","steps":9000,"resting_hr":null}]');
  select resting_hr, steps into v, n from public.daily where date = '2026-01-01';
  if v <> 52 or n <> 9000 then raise exception 'CHECK FAILED: db_upsert_never_nulls rhr=% steps=%', v, n; end if;

  -- db_flags_implausible (daily + weight)
  perform public.upsert_daily('[{"date":"2026-01-04","resting_hr":19}]');
  select flagged into f from public.daily where date = '2026-01-04';
  if not f then raise exception 'CHECK FAILED: rhr 19 not flagged'; end if;
  select flagged into f from public.daily where date = '2026-01-02';
  if f then raise exception 'CHECK FAILED: rhr 51 flagged'; end if;
  perform public.upsert_weight('[{"date":"2026-01-05","weight_kg":75},{"date":"2026-01-06","weight_kg":80}]');
  select flagged into f from public.weight where date = '2026-01-06';
  if not f then raise exception 'CHECK FAILED: 5 kg jump not flagged'; end if;
  select flagged into f from public.weight where date = '2026-01-05';
  if f then raise exception 'CHECK FAILED: first weigh-in flagged'; end if;

  -- other upserts work
  perform public.upsert_activities('[{"activity_id":1,"start_utc":"2026-03-01T03:30:00Z","local_date":"2026-02-28","type":"running","distance_m":8000}]');
  perform public.upsert_vo2max('[{"date":"2026-01-15","sport":"running","value":49}]');
  perform public.upsert_profile('{"height_cm":180,"birth_date":"1986-04-02","sex":"male"}');

  -- user B sees none of A's rows
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from (
    select 1 from public.daily union all select 1 from public.weight union all select 1 from public.activities
    union all select 1 from public.vo2max union all select 1 from public.profile) x;
  if n <> 0 then raise exception 'CHECK FAILED: db_two_users_isolated, B sees % rows', n; end if;
  perform public.upsert_daily('[{"date":"2026-01-01","steps":1}]');
  select count(*) into n from public.daily;
  if n <> 1 then raise exception 'CHECK FAILED: B should see exactly its own row, sees %', n; end if;

  -- db_anon_sees_nothing
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin
    select count(*) into n from public.daily;
    if n <> 0 then raise exception 'CHECK FAILED: db_anon_sees_nothing, anon sees % rows', n; end if;
  exception when insufficient_privilege then null;  -- denied outright is also a pass
  end;
  begin
    perform public.upsert_daily('[{"date":"2026-01-09","steps":1}]');
    raise exception 'CHECK FAILED: anon could call upsert_daily';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  raise exception 'ALL_CHECKS_PASSED';
end $$;
