-- Personal health dashboard: schema, row-level security and safe upsert functions.
-- Every table belongs to a user; every policy restricts rows to auth.uid().
-- Values are stored in SI units (m, s, kg, kcal, bpm).

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------
create table public.daily (
  user_id            uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date               date not null,
  steps              integer,
  distance_m         double precision,
  resting_hr         double precision,
  hrv_night_ms       double precision,
  sleep_s            integer,
  sleep_score        double precision,
  stress_avg         double precision,
  body_battery_high  double precision,
  body_battery_low   double precision,
  kcal_total_garmin  double precision,
  kcal_active_garmin double precision,
  kcal_bmr_garmin    double precision,
  flagged            boolean not null default false,
  source             text,
  updated_at         timestamptz not null default now(),
  primary key (user_id, date)
);

create table public.weight (
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date         date not null,
  weight_kg    double precision,
  body_fat_pct double precision,
  flagged      boolean not null default false,
  source       text,
  updated_at   timestamptz not null default now(),
  primary key (user_id, date)
);

create table public.activities (
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  activity_id   bigint not null,
  start_utc     timestamptz,
  local_date    date,
  type          text,
  distance_m    double precision,
  duration_s    double precision,
  avg_hr        double precision,
  max_hr        double precision,
  kcal          double precision,
  steps         integer,
  elev_gain_m   double precision,
  training_load double precision,
  source        text,
  updated_at    timestamptz not null default now(),
  primary key (user_id, activity_id)
);
create index activities_user_local_date on public.activities (user_id, local_date);

create table public.vo2max (
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date       date not null,
  sport      text not null default 'running',
  value      double precision,
  source     text,
  updated_at timestamptz not null default now(),
  primary key (user_id, date, sport)
);

create table public.profile (
  user_id    uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  height_cm  double precision,
  birth_date date,
  sex        text check (sex in ('male', 'female')),
  source     text,
  updated_at timestamptz not null default now()
);

create table public.settings (
  user_id       uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  weight_goal   text not null default 'maintain' check (weight_goal in ('maintain', 'lose', 'gain')),
  sleep_band_lo double precision not null default 7,
  sleep_band_hi double precision not null default 9,
  easy_hr_lo    integer not null default 140,
  easy_hr_hi    integer not null default 150,
  updated_at    timestamptz not null default now(),
  check (sleep_band_lo < sleep_band_hi),
  check (easy_hr_lo < easy_hr_hi)
);

create table public.sync_log (
  id      bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  ran_at  timestamptz not null default now(),
  ok      boolean not null,
  fetched jsonb,
  error   text
);
create index sync_log_user_ran_at on public.sync_log (user_id, ran_at desc);

------------------------------------------------------------------------------
-- Row-level security: owner-only, for every table
------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['daily', 'weight', 'activities', 'vo2max', 'profile', 'settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (user_id = (select auth.uid()))', t || '_select_own', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (user_id = (select auth.uid()))', t || '_insert_own', t);
    execute format('create policy %I on public.%I for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t || '_update_own', t);
    execute format('create policy %I on public.%I for delete to authenticated using (user_id = (select auth.uid()))', t || '_delete_own', t);
  end loop;
end $$;

-- The sync log is written by the sync function; I can read and clear my own entries.
alter table public.sync_log enable row level security;
create policy sync_log_select_own on public.sync_log for select to authenticated using (user_id = (select auth.uid()));
create policy sync_log_delete_own on public.sync_log for delete to authenticated using (user_id = (select auth.uid()));

-- The publishable (anon) key gets nothing at all.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon, public;

------------------------------------------------------------------------------
-- Upsert functions
--  * rows: a JSON array of records (profile takes one object)
--  * merge rule: a value already stored is never replaced by null/absent
--  * returns {"inserted", "updated", "unchanged"}
--  * runs as the caller (RLS applies). The sync function, running with the
--    service role, passes for_user explicitly; nobody else may.
------------------------------------------------------------------------------
create or replace function public._caller(for_user uuid)
returns uuid
language plpgsql stable security invoker set search_path = ''
as $$
declare uid uuid := auth.uid();
begin
  if uid is not null then
    if for_user is not null and for_user <> uid then
      raise exception 'for_user is only for the sync service' using errcode = '42501';
    end if;
    return uid;
  end if;
  if for_user is not null and coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return for_user;
  end if;
  raise exception 'Sign-in required' using errcode = '42501';
end $$;

create or replace function public.upsert_daily(rows jsonb, for_user uuid default null)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := public._caller(for_user);
  ignore text[] := array['updated_at', 'flagged', 'source', 'user_id'];
  r jsonb; cur jsonb; m public.daily;
  ins int := 0; upd int := 0; same int := 0;
begin
  if jsonb_typeof(rows) <> 'array' then raise exception 'rows must be a JSON array'; end if;
  for r in select value from jsonb_array_elements(rows) order by value ->> 'date' loop
    select to_jsonb(d) into cur from public.daily d where d.user_id = uid and d.date = (r ->> 'date')::date;
    m := jsonb_populate_record(null::public.daily, coalesce(cur, '{}') || jsonb_strip_nulls(r) || jsonb_build_object('user_id', uid));
    if cur is not null and (to_jsonb(m) - ignore) = (cur - ignore) then same := same + 1; continue; end if;
    m.flagged := m.resting_hr is not null and (m.resting_hr < 25 or m.resting_hr > 120);
    m.updated_at := now();
    insert into public.daily values (m.*)
    on conflict (user_id, date) do update set
      steps = excluded.steps, distance_m = excluded.distance_m, resting_hr = excluded.resting_hr,
      hrv_night_ms = excluded.hrv_night_ms, sleep_s = excluded.sleep_s, sleep_score = excluded.sleep_score,
      stress_avg = excluded.stress_avg, body_battery_high = excluded.body_battery_high,
      body_battery_low = excluded.body_battery_low, kcal_total_garmin = excluded.kcal_total_garmin,
      kcal_active_garmin = excluded.kcal_active_garmin, kcal_bmr_garmin = excluded.kcal_bmr_garmin,
      flagged = excluded.flagged, source = excluded.source, updated_at = excluded.updated_at;
    if cur is null then ins := ins + 1; else upd := upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'unchanged', same);
end $$;

create or replace function public.upsert_weight(rows jsonb, for_user uuid default null)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := public._caller(for_user);
  ignore text[] := array['updated_at', 'flagged', 'source', 'user_id'];
  r jsonb; cur jsonb; m public.weight; prev double precision;
  ins int := 0; upd int := 0; same int := 0;
begin
  if jsonb_typeof(rows) <> 'array' then raise exception 'rows must be a JSON array'; end if;
  for r in select value from jsonb_array_elements(rows) order by value ->> 'date' loop
    select to_jsonb(w) into cur from public.weight w where w.user_id = uid and w.date = (r ->> 'date')::date;
    m := jsonb_populate_record(null::public.weight, coalesce(cur, '{}') || jsonb_strip_nulls(r) || jsonb_build_object('user_id', uid));
    if cur is not null and (to_jsonb(m) - ignore) = (cur - ignore) then same := same + 1; continue; end if;
    select w.weight_kg into prev from public.weight w
      where w.user_id = uid and w.date < m.date and w.weight_kg is not null and not w.flagged
      order by w.date desc limit 1;
    m.flagged := prev is not null and m.weight_kg is not null and abs(m.weight_kg - prev) > 4.536;
    m.updated_at := now();
    insert into public.weight values (m.*)
    on conflict (user_id, date) do update set
      weight_kg = excluded.weight_kg, body_fat_pct = excluded.body_fat_pct,
      flagged = excluded.flagged, source = excluded.source, updated_at = excluded.updated_at;
    if cur is null then ins := ins + 1; else upd := upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'unchanged', same);
end $$;

create or replace function public.upsert_activities(rows jsonb, for_user uuid default null)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := public._caller(for_user);
  ignore text[] := array['updated_at', 'source', 'user_id'];
  r jsonb; cur jsonb; m public.activities;
  ins int := 0; upd int := 0; same int := 0;
begin
  if jsonb_typeof(rows) <> 'array' then raise exception 'rows must be a JSON array'; end if;
  for r in select value from jsonb_array_elements(rows) order by value ->> 'start_utc' loop
    select to_jsonb(a) into cur from public.activities a where a.user_id = uid and a.activity_id = (r ->> 'activity_id')::bigint;
    m := jsonb_populate_record(null::public.activities, coalesce(cur, '{}') || jsonb_strip_nulls(r) || jsonb_build_object('user_id', uid));
    if cur is not null and (to_jsonb(m) - ignore) = (cur - ignore) then same := same + 1; continue; end if;
    m.updated_at := now();
    insert into public.activities values (m.*)
    on conflict (user_id, activity_id) do update set
      start_utc = excluded.start_utc, local_date = excluded.local_date, type = excluded.type,
      distance_m = excluded.distance_m, duration_s = excluded.duration_s, avg_hr = excluded.avg_hr,
      max_hr = excluded.max_hr, kcal = excluded.kcal, steps = excluded.steps,
      elev_gain_m = excluded.elev_gain_m, training_load = excluded.training_load,
      source = excluded.source, updated_at = excluded.updated_at;
    if cur is null then ins := ins + 1; else upd := upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'unchanged', same);
end $$;

create or replace function public.upsert_vo2max(rows jsonb, for_user uuid default null)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := public._caller(for_user);
  ignore text[] := array['updated_at', 'source', 'user_id'];
  r jsonb; cur jsonb; m public.vo2max;
  ins int := 0; upd int := 0; same int := 0;
begin
  if jsonb_typeof(rows) <> 'array' then raise exception 'rows must be a JSON array'; end if;
  for r in select value from jsonb_array_elements(rows) order by value ->> 'date' loop
    select to_jsonb(v) into cur from public.vo2max v
      where v.user_id = uid and v.date = (r ->> 'date')::date and v.sport = coalesce(r ->> 'sport', 'running');
    m := jsonb_populate_record(null::public.vo2max,
           coalesce(cur, '{}') || jsonb_build_object('sport', 'running') || jsonb_strip_nulls(r) || jsonb_build_object('user_id', uid));
    if cur is not null and (to_jsonb(m) - ignore) = (cur - ignore) then same := same + 1; continue; end if;
    m.updated_at := now();
    insert into public.vo2max values (m.*)
    on conflict (user_id, date, sport) do update set
      value = excluded.value, source = excluded.source, updated_at = excluded.updated_at;
    if cur is null then ins := ins + 1; else upd := upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', ins, 'updated', upd, 'unchanged', same);
end $$;

create or replace function public.upsert_profile(p jsonb, for_user uuid default null)
returns jsonb
language plpgsql security invoker set search_path = ''
as $$
declare
  uid uuid := public._caller(for_user);
  ignore text[] := array['updated_at', 'source', 'user_id'];
  cur jsonb; m public.profile;
begin
  if jsonb_typeof(p) <> 'object' then raise exception 'profile must be a JSON object'; end if;
  select to_jsonb(x) into cur from public.profile x where x.user_id = uid;
  m := jsonb_populate_record(null::public.profile, coalesce(cur, '{}') || jsonb_strip_nulls(p) || jsonb_build_object('user_id', uid));
  if cur is not null and (to_jsonb(m) - ignore) = (cur - ignore) then
    return jsonb_build_object('inserted', 0, 'updated', 0, 'unchanged', 1);
  end if;
  m.updated_at := now();
  insert into public.profile values (m.*)
  on conflict (user_id) do update set
    height_cm = excluded.height_cm, birth_date = excluded.birth_date, sex = excluded.sex,
    source = excluded.source, updated_at = excluded.updated_at;
  return jsonb_build_object('inserted', (cur is null)::int, 'updated', (cur is not null)::int, 'unchanged', 0);
end $$;

-- Only signed-in users and the sync service may call these.
revoke execute on function public._caller(uuid) from public, anon;
revoke execute on function public.upsert_daily(jsonb, uuid) from public, anon;
revoke execute on function public.upsert_weight(jsonb, uuid) from public, anon;
revoke execute on function public.upsert_activities(jsonb, uuid) from public, anon;
revoke execute on function public.upsert_vo2max(jsonb, uuid) from public, anon;
revoke execute on function public.upsert_profile(jsonb, uuid) from public, anon;
grant execute on function public._caller(uuid) to authenticated, service_role;
grant execute on function public.upsert_daily(jsonb, uuid) to authenticated, service_role;
grant execute on function public.upsert_weight(jsonb, uuid) to authenticated, service_role;
grant execute on function public.upsert_activities(jsonb, uuid) to authenticated, service_role;
grant execute on function public.upsert_vo2max(jsonb, uuid) to authenticated, service_role;
grant execute on function public.upsert_profile(jsonb, uuid) to authenticated, service_role;
