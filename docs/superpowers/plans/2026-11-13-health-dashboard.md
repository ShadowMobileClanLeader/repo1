# Personal Health Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local, private health dashboard on macOS that turns my Garmin export and the Garmin Personal API into one self-contained HTML health report.

**Architecture:** Each source module normalises its input into shared record types. Those records are upserted into one SQLite file. Metric modules compute derived series from it, and a build step renders a single HTML file with the data embedded as JSON and the vendored charting libraries inlined. The `hd` CLI ties it together.

**Tech Stack:** Python 3.12, uv, SQLite (stdlib `sqlite3`), pandas, Jinja2, httpx, python-dotenv, pytest. For charts, Observable Plot 0.6.16 and d3 7.9.0, vendored.

**Spec:** `docs/superpowers/specs/2026-11-13-health-dashboard-design.md`

**Where this runs:** on my Mac, in a local Claude Code session inside a clone of this repo, on branch `claude/practical-brown-r8iemm`. Real health data never leaves the Mac. Each **Phase** ends with a **CHECK-IN**: run it on real data, show the result, and wait for my go-ahead.

## Global Constraints

- Python 3.12. Managed with `uv`. CLI entry point is `hd`, set via `[project.scripts]`.
- Runtime dependencies are limited to: `pandas`, `jinja2`, `httpx`, `python-dotenv`. Dev dependency: `pytest`. CLI parsing uses `argparse` (stdlib). Config reading uses `tomllib` (stdlib).
- `.gitignore` must contain `.env`, `data/`, `out/` and `*.db`. It is committed before any of those paths exist.
- Database values are stored in SI units: m, s, kg, kcal and bpm. Imperial conversion happens only in `hd/units.py`, at render time.
- Day key: Garmin `calendarDate` (device-local). Activities use their local start date. UTC timestamps are stored alongside.
- Upserts never overwrite a non-null value with null. A newer source wins field by field.
- Rolling 7-day averages need at least 4 days with data; otherwise the value is `None`.
- Implausible values are kept in the database but flagged, and left out of averages and the index. That means resting heart rate below 25 or above 120 bpm, or a weight change of more than 10 lb (4.536 kg) from the previous weigh-in.
- The dashboard HTML makes zero network requests. No `http(s)://` appears in any `src`, `href`, `fetch` or `import`.
- The Garmin API key is read from `.env` as `GARMIN_PERSONAL_API_KEY`. It is never printed or logged.
- Fixed copy: these strings are used verbatim.
  - Footer: "Trends and correlations from your own data, not diagnoses. Correlations don't mean one thing causes another. If something here worries you, talk to a doctor."
  - Health index label: "Personal index from your own data, not a medical score."
  - Energy label: "Estimate, typically within ±10–20% for an individual. Not dietary advice."
  - Any correlation display: "Correlation, not cause."
- Default config values:
  - `weight_goal = "maintain"`
  - `sleep_band_h = [7, 9]`
  - `easy_hr_band = [140, 150]`
- Tests use synthetic fixtures only. Never commit real data.

## Review Focus

1. **The watch doesn't record HRV, or a sensor is missing for a stretch.** Tiles show "no data yet". The health index still computes from the other 3 components. (Test in Task 8.)
2. **History is shorter than the 180-day baseline,** for example a new watch. The health index is blank for weeks without enough baseline, meaning fewer than 60 days with data in the window, and shows "Needs more history" instead of misleading scores. (Test in Task 8.)
3. **A newer export overlaps an older export and API-fetched data.** There are no duplicate rows and no values blanked. Re-running an import changes nothing. (Tests in Tasks 3 and 5.)
4. **The API key is expired or invalid, or the Mac is offline, during `hd refresh`.** It prints a clear message ("create a new key in Garmin Connect settings and update .env" on a 401), still rebuilds from stored data, and exits 0. (Test in Task 15.)
5. **Height, birth date or sex is missing from both the export and `config.toml`.** The energy section shows "Add height_cm, birth_date and sex to config.toml to see energy estimates" instead of crashing the build. (Test in Task 12.)

---

## File Structure

```
.gitignore                     # private paths first
pyproject.toml                 # uv project, hd entry point
config.example.toml            # committed template; copied to config.toml (gitignored)
README.md                      # setup, run, refresh, key renewal
hd/__init__.py
hd/cli.py                      # argparse subcommands
hd/config.py                   # load config.toml + defaults
hd/records.py                  # shared normalised dataclasses
hd/units.py                    # SI ↔ imperial
hd/store.py                    # schema, upsert, reads, flags
hd/inventory.py                # read-only export summary
hd/sources/garmin_export.py    # export ZIP → records
hd/sources/garmin_api.py       # Personal API → records
hd/metrics/daily.py            # rolling averages, tiles
hd/metrics/health_index.py
hd/metrics/report_card.py
hd/metrics/recovery.py
hd/metrics/running.py
hd/metrics/energy.py
hd/dashboard/build.py          # assemble JSON, render, write out/dashboard.html
hd/dashboard/template.html.j2
hd/dashboard/app.js            # range toggle, charts, calculator
hd/dashboard/style.css
hd/dashboard/vendor/d3.min.js, plot.umd.min.js
scripts/vendor.sh              # one-time download of pinned d3/Plot
tests/…                        # mirrors hd/, synthetic fixtures in tests/fixtures/
```

`config.toml` is gitignored: it isn't secret, but it holds personal profile data. `config.example.toml` is committed.

---

## Phase 1: Foundation and export inventory (finishes Phase 0)

### Task 1: Project skeleton, privacy guards and config

**Files:**
- Create: `.gitignore`, `pyproject.toml`, `config.example.toml`, `hd/__init__.py`, `hd/cli.py`, `hd/config.py`, `README.md` (stub)
- Test: `tests/test_privacy.py`, `tests/test_config.py`

**Interfaces:**
- Produces:
  - `load_config(path: Path = Path("config.toml")) -> Config`
  - `Config` is a dataclass with fields: `height_cm: float|None`, `birth_date: date|None`, `sex: Literal["male","female"]|None`, `weight_goal: Literal["maintain","lose","gain"]`, `sleep_band_h: tuple[float,float]`, `easy_hr_band: tuple[int,int]`, `db_path: Path = Path("data/health.db")`, `out_path: Path = Path("out/dashboard.html")`
  - `main(argv: list[str]|None = None) -> int` in `hd/cli.py`

- [ ] **Step 1: Create `.gitignore` FIRST and commit it alone.** Entries: `.env`, `data/`, `out/`, `*.db`, `config.toml`, `.venv/`, `__pycache__/`. Then run `git commit -m "chore: ignore private data paths"`.
- [ ] **Step 2: Write failing tests**
  - `test_gitignore_covers_private_paths`: asserts that each of `.env`, `data/`, `out/`, `*.db` and `config.toml` is a line in `.gitignore`.
  - `test_config_defaults_when_file_missing`: `load_config(tmp_path/"none.toml")` returns `weight_goal == "maintain"`, `sleep_band_h == (7, 9)`, `easy_hr_band == (140, 150)` and `height_cm is None`.
  - `test_config_reads_profile`: a TOML file with `height_cm = 180`, `birth_date = 1986-04-02` and `sex = "male"` is parsed into those values.
  - `test_config_rejects_bad_weight_goal`: `"bulk"` raises `ValueError`.
- [ ] **Step 3: Run `uv run pytest -q`.** Expected: FAIL (module missing).
- [ ] **Step 4: Implement `pyproject.toml`, `hd/config.py` and the `hd/cli.py` skeleton.** The subcommands `inventory`, `import-export`, `build`, `refresh` and `api-probe` print "not implemented yet" and return 2. Also write `config.example.toml` with the defaults and commented profile keys.
- [ ] **Step 5: Run `uv run pytest -q` and `uv run hd --help`.** Expected: tests PASS, and help lists the 5 subcommands.
- [ ] **Step 6: Commit** with `git commit -m "feat: project skeleton, config loader, privacy guards"`.

### Task 2: `hd inventory <zip>`: read-only export summary

**Files:**
- Create: `hd/inventory.py`
- Test: `tests/test_inventory.py`, with a fixture builder `tests/fixtures/make_export.py`

**Interfaces:**
- Consumes: `hd/cli.py`
- Produces:
  - `inventory(zip_path: Path) -> InventoryReport`
  - `InventoryReport` is a dataclass with fields `files_by_ext: dict[str,int]`, `folders: dict[str,int]`, `json_files: list[JsonFileInfo]` and `metrics_detected: dict[str, DateRange|None]`
  - `JsonFileInfo` has `path`, `n_records`, `top_level_keys: list[str]`, `date_min` and `date_max`
  - `format_report(r: InventoryReport) -> str`
  - Fixture builder: `make_export(tmp_path) -> Path`, which writes a small fake export ZIP. Later tasks reuse it.

- [ ] **Step 1: Write the fixture builder.** `make_export` creates a ZIP with fake values in the layout Garmin exports usually have. *This layout is expected but unconfirmed; Task 4 corrects it to match the real inventory.*
  - `DI_CONNECT/DI-Connect-Aggregator/UDSFile_2026-01-01_2026-04-10.json`: daily summaries with `calendarDate`, `totalSteps`, `restingHeartRate`, `totalKilocalories`, `activeKilocalories`, `bmrKilocalories`, `totalDistanceMeters`, `averageStressLevel`, `bodyBatteryHighestValue`, `bodyBatteryLowestValue`
  - `DI_CONNECT/DI-Connect-Wellness/2026-01-01_2026-04-10_sleepData.json`
  - `DI_CONNECT/DI-Connect-Fitness/user_summarizedActivities.json`
  - `DI_CONNECT/DI-Connect-Metrics/MetricsMaxMetData_20260101_20260410.json`
  - `DI_CONNECT/DI-Connect-User/user_profile.json`
  - one `.fit` file inside `DI-Connect-Uploaded-Files/` (zipped)
- [ ] **Step 2: Write failing tests**
  - `test_inventory_counts_files_by_extension`: `{".json": 5, ".zip": 1}`
  - `test_inventory_detects_date_range`: the UDS file gives `date_min == date(2026,1,1)` and `date_max == date(2026,4,10)`
  - `test_inventory_detects_metrics`: `metrics_detected` has non-None ranges for `"steps"`, `"resting_hr"`, `"sleep"`, `"activities"` and `"vo2max"`, and `None` for `"hrv"` (not in the fixture)
  - `test_inventory_does_not_modify_zip`: the file's SHA-256 is unchanged after `inventory()`
  - `test_inventory_never_prints_values`: `format_report` output contains no `restingHeartRate` value from the fixture. Only key names, counts and dates are allowed.
- [ ] **Step 3: Run `uv run pytest tests/test_inventory.py -q`.** Expected: FAIL.
- [ ] **Step 4: Implement `inventory()`.** Open the ZIP read-only with `zipfile`, and never extract it to disk. Look for dates in any key matching `calendarDate|startTimeLocal|startTimeGMT|date` (ISO strings or epoch milliseconds). Map metrics by key-name keywords:
  - `totalSteps` → steps
  - `restingHeartRate` → resting_hr
  - `sleep` → sleep
  - `hrv` or `lastNightAvg` → hrv
  - `weight` → weight
  - `activityId` → activities
  - `vo2MaxValue` or `maxMet` → vo2max
  - `averageStressLevel` → stress

  Wire it up as `hd inventory <zip>`.
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit** with `git commit -m "feat: read-only export inventory"`.

**CHECK-IN (Phase 1):**
- I place a copy of my export at a path of my choice. Run `uv run hd inventory <path>` and show me the report.
- Acceptance:
  - the report lists file types, folders, the overall date range, and metric coverage, including whether HRV and weight exist
  - the original ZIP's checksum is unchanged
  - no health values are printed
- Record the real file layout in `docs/export-layout.md`: paths and key names only, no values. Commit it.

---

## Phase 2: Storage and export import

### Task 3: Records, units and store

**Files:**
- Create: `hd/records.py`, `hd/units.py`, `hd/store.py`
- Test: `tests/test_units.py`, `tests/test_store.py`

**Interfaces:**
- Produces:
  - Frozen dataclasses in `hd/records.py`. Every field except the key is optional, defaulting to `None`. Each has `source: str`.
    - `DailyRecord(date, steps, distance_m, resting_hr, hrv_night_ms, sleep_s, sleep_score, stress_avg, body_battery_high, body_battery_low, kcal_total_garmin, kcal_active_garmin, kcal_bmr_garmin, source)`
    - `WeightRecord(date, weight_kg, body_fat_pct, source)`
    - `ActivityRecord(activity_id: int, start_utc: datetime, local_date: date, type: str, distance_m, duration_s, avg_hr, max_hr, kcal, steps, elev_gain_m, training_load, source)`
    - `Vo2Record(date, sport: str, value: float, source)`
    - `ProfileRecord(height_cm, birth_date, sex, source)`
  - `hd/units.py`:
    - `kg_to_lb(x)`, `m_to_mi(x)`, `pace_s_per_km_to_s_per_mi(x)`, `c_to_f(x)`, `fmt_pace(s_per_mi) -> "m:ss"`, `fmt_duration(s) -> "7 h 12 m"`
    - All return `None` when given `None`.
  - `hd/store.py`:
    - `connect(db_path: Path) -> sqlite3.Connection`, which creates the schema (spec §5) and adds a `flagged INTEGER DEFAULT 0` column to `daily` and `weight`
    - `upsert(conn, records: Iterable[Record]) -> UpsertStats(inserted:int, updated:int, unchanged:int)`
    - `read_daily(conn, start: date|None, end: date|None) -> pd.DataFrame`, indexed by date and including every calendar day in the range (missing days are all-NaN rows)
    - `read_weight(...)`, `read_activities(...)` and `read_vo2(...)` return DataFrames
    - `read_profile(conn, config: Config) -> ProfileRecord`, where config values win
    - `flag_implausible(conn) -> int`

- [ ] **Step 1: Write failing tests**
  - `test_kg_to_lb`: `kg_to_lb(75) == pytest.approx(165.347, abs=1e-3)`
  - `test_m_to_mi`: `m_to_mi(1609.344) == 1`
  - `test_pace_conversion`: `pace_s_per_km_to_s_per_mi(360) == pytest.approx(579.36, abs=0.01)`
  - `test_fmt_pace`: `fmt_pace(579.36) == "9:39"`
  - `test_units_none_passthrough`
  - `test_upsert_is_idempotent`: upserting the same 3 `DailyRecord`s twice gives `UpsertStats(0,0,3)` the second time
  - `test_upsert_never_overwrites_with_null`: an existing `resting_hr=52` and a new record with `resting_hr=None, steps=9000` leave `resting_hr == 52` and `steps == 9000`
  - `test_upsert_newer_value_wins`: an existing value of 52 and a new value of 50 give 50
  - `test_read_daily_fills_missing_days`: rows for Jan 1 and Jan 3, read over Jan 1–3, give 3 rows, with all-NaN values on Jan 2
  - `test_flag_implausible`: `resting_hr=19` is flagged, `resting_hr=52` is not. A weight of 75 kg followed by 80 kg the next day flags the second weigh-in.
  - `test_profile_config_overrides_export`
- [ ] **Step 2: Run `uv run pytest tests/test_units.py tests/test_store.py -q`.** Expected: FAIL.
- [ ] **Step 3: Implement `units.py`, `records.py` and `store.py`.** Upsert is per field: `INSERT … ON CONFLICT(key) DO UPDATE SET col = COALESCE(excluded.col, col)`, comparing values first to count `unchanged`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: records, unit conversion, SQLite store with safe upserts"`.

### Task 4: Garmin export parser

**Files:**
- Create: `hd/sources/__init__.py`, `hd/sources/garmin_export.py`
- Modify: `tests/fixtures/make_export.py`, so it matches `docs/export-layout.md` from the Phase 1 check-in
- Test: `tests/test_garmin_export.py`

**Interfaces:**
- Consumes: the records from Task 3, and the fixture builder from Task 2
- Produces: `parse_export(zip_path: Path) -> ParseResult`. `ParseResult` has `records: list[Record]` and `skipped: dict[str,int]` (reason → count).

- [ ] **Step 1: Update the fixture builder so its paths and key names match `docs/export-layout.md` exactly.** Fake values only. Include:
  - a DST-change day
  - an activity starting at `2026-03-01T03:30:00Z` with a local offset of −8 h
  - a duplicate activity ID across two files
  - one unknown JSON file
- [ ] **Step 2: Write failing tests**
  - `test_parses_daily_fields`: a fixture day maps to `DailyRecord` with `steps`, `resting_hr`, `kcal_total_garmin` and `distance_m` equal to the fixture values
  - `test_activity_local_date_from_local_start`: the activity above gets `local_date == date(2026,2,28)` and keeps `start_utc` in UTC
  - `test_sleep_seconds_and_score`
  - `test_hrv_parsed_when_present`, and `test_no_hrv_file_yields_none_hrv` (Review Focus 1)
  - `test_weight_grams_converted_to_kg`: Garmin stores weight in grams, so 75000 → 75.0. *Confirm the unit against the real layout.*
  - `test_vo2max_records`
  - `test_profile_from_export`: height, birth date and sex come out as a `ProfileRecord` when present
  - `test_duplicate_activity_ids_deduplicated`
  - `test_unknown_file_counted_in_skipped`: `skipped["unknown_file"] == 1`, with no exception
- [ ] **Step 3: Run `uv run pytest tests/test_garmin_export.py -q`.** Expected: FAIL.
- [ ] **Step 4: Implement `parse_export()`.** Use one small function per file family, dispatched by a path pattern table at the top of the module. Epoch-millisecond timestamps are converted with `datetime.fromtimestamp(ms/1000, tz=UTC)`. Local offsets come from the `startTimeLocal` vs `startTimeGMT` pair.
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit** with `git commit -m "feat: parse Garmin export into normalised records"`.

### Task 5: `hd import-export <zip>`

**Files:**
- Modify: `hd/cli.py`
- Create: `hd/importer.py`
- Test: `tests/test_import_export.py`

**Interfaces:**
- Consumes: `parse_export`, `connect`, `upsert` and `flag_implausible`
- Produces: `import_export(zip_path: Path, config: Config) -> ImportSummary`
  - `ImportSummary` has per-table `UpsertStats`, `date_ranges: dict[str,(date,date)]`, `skipped`, `flagged:int` and `copied_to: Path`

- [ ] **Step 1: Write failing tests**
  - `test_import_copies_zip_to_data_raw`: `copied_to` is under `data/raw/`, and the original's SHA-256 is unchanged
  - `test_import_twice_changes_nothing`: the second run has `inserted == updated == 0` for every table (Review Focus 3)
  - `test_import_overlapping_newer_export_keeps_values`: export A has resting heart rate on Jan 5, export B has steps on Jan 5 but no resting heart rate. After both, the database has both values (Review Focus 3).
  - `test_import_is_single_transaction`: patch `upsert` to raise partway through, and assert the database has 0 rows
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `import_export`.** Copy the ZIP with `shutil.copy2` to `data/raw/<original-name>`, and skip the copy if an identical checksum is already there. Parse, upsert in one transaction, flag implausible values, and print the summary: table, rows, inserted/updated/unchanged, date range, skipped, flagged. Wire it into the CLI.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: import-export command with copy, single transaction, summary"`.

**CHECK-IN (Phase 2):**
- Run `uv run hd import-export <my zip>`, then run it again. Show me both summaries.
- Acceptance:
  - row counts and date ranges look right to me
  - the second run reports 0 inserted and 0 updated
  - the flagged count is small and explained

---

## Phase 3: First dashboard (tiles and Health trends)

### Task 6: Daily metrics and headline tiles

**Files:**
- Create: `hd/metrics/__init__.py`, `hd/metrics/daily.py`
- Test: `tests/test_daily.py`

**Interfaces:**
- Consumes: `read_daily` and `read_weight`
- Produces:
  - `rolling7(s: pd.Series) -> pd.Series`, with a minimum of 4 values
  - `apply_not_worn(df) -> df`: where steps are 0 and resting heart rate is null, steps are set to NaN
  - `usual_range(s: pd.Series, end: date, days: int = 180) -> tuple[float,float]|None`: the 25th–75th percentile, needing at least 60 values
  - `tiles(conn, today: date) -> list[Tile]`
  - `Tile` has `key`, `label`, `value_si: float|None`, `delta_si: float|None` (vs the 7-day average 90 days earlier) and `better_when: Literal["lower","higher","neutral"]`. Keys are `resting_hr`, `hrv`, `sleep` and `weight`.

- [ ] **Step 1: Write failing tests**
  - `test_rolling7_needs_four_days`: 3 values in the window give NaN, 4 give their mean
  - `test_not_worn_day_excluded`
  - `test_flagged_values_excluded_from_rolling`
  - `test_tiles_delta_vs_90_days_ago`: 7-day average resting heart rate of 52 now and 55 ninety days earlier gives `delta_si == -3`
  - `test_tile_missing_metric_is_none`: no HRV data gives `value_si is None` (Review Focus 1)
  - `test_usual_range_needs_60_values`
- [ ] **Step 2: Run `uv run pytest tests/test_daily.py -q`.** Expected: FAIL.
- [ ] **Step 3: Implement `daily.py`.** Weight is a 7-day average of weigh-ins, carried forward up to 14 days.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: daily rolling metrics and headline tiles"`.

### Task 7: Dashboard build, page shell and Health trends

**Files:**
- Create: `scripts/vendor.sh`, `hd/dashboard/vendor/*`, `hd/dashboard/build.py`, `hd/dashboard/template.html.j2`, `hd/dashboard/app.js`, `hd/dashboard/style.css`
- Modify: `hd/cli.py` (`build`)
- Test: `tests/test_build.py`, with the fixture database built via `make_export` and `import_export`

**Interfaces:**
- Consumes: `tiles`, `rolling7`, `usual_range`, `read_*` and `units`
- Produces:
  - `build_dashboard(config: Config, today: date|None = None, open_browser: bool = False) -> Path`
  - `collect_payload(conn, config, today) -> dict`. Later tasks add keys to this payload:
    - `"meta"`: `generated_at` and `last_data_date` per source
    - `"tiles"`
    - `"series"`: per-day lists for `resting_hr`, `hrv`, `sleep_h` and `weight_lb`, each with raw and 7-day average values, already in imperial units
    - `"bands"`
  - `app.js` exposes `render(payload, rangeDays)`. Each section is a function `renderX(el, payload, range)`.

- [ ] **Step 1: Write and run `scripts/vendor.sh`.** It downloads `https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js` and `https://cdn.jsdelivr.net/npm/@observablehq/plot@0.6.16/dist/plot.umd.min.js` into `hd/dashboard/vendor/`. Commit the files. This is the project's only network fetch for the page, done once at development time.
- [ ] **Step 2: Write failing tests**
  - `test_build_writes_single_html`: the output exists under `out/`
  - `test_html_has_no_external_requests`: a regex over the HTML finds no `(src|href)=["']https?://`, no `fetch(` and no `import(` with http
  - `test_html_contains_sections`: the ids `header`, `tiles`, `health-trends` and `footer` are present
  - `test_footer_copy_verbatim`
  - `test_payload_units_imperial`: a fixture weight of 75 kg appears in the payload as approximately 165.3
  - `test_section_without_data_shows_placeholder`: an empty database still builds, showing "No data yet"
- [ ] **Step 3: Run `uv run pytest tests/test_build.py -q`.** Expected: FAIL.
- [ ] **Step 4: Implement `build.py`, the template, `app.js` and `style.css`.** Follow mockup A:
  - **Layout:** max width 1120 px, cards with a 14 px radius, Inter falling back to the system UI font (no web fonts are fetched).
  - **Colour:** tokens on `:root`, with dark mode via `prefers-color-scheme`.
  - **Range toggle:** 30 d / **90 d** (default) / 1 y / All. The selection is remembered in `localStorage`, wrapped in try/catch.
  - **Charts:** daily values as a thin line, the 7-day average bold, breaks where data is missing, the HRV usual range shaded, and the sleep band drawn as a dashed line. Every chart has a tooltip.
  - **Other content:** a "talk to a doctor" note under Health trends, and the footer copy.

  JSON and the vendored JS are inlined into the HTML. `hd build` opens the result with `open` (macOS).
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit** with `git commit -m "feat: self-contained dashboard with tiles and health trends"`.

**CHECK-IN (Phase 3):**
- Run `uv run hd build` on real data. Take a screenshot for me with headless Chromium if it's available locally, otherwise I look in my browser.
- Acceptance:
  - the tiles match what Garmin Connect shows, within rounding
  - the range toggle works
  - gaps show as breaks
  - it works in both dark and light mode
  - the browser's network tab shows no external requests

---

## Phase 4: Health trend line and monthly report card

### Task 8: Health index

**Files:**
- Create: `hd/metrics/health_index.py`
- Test: `tests/test_health_index.py`

**Interfaces:**
- Consumes: `read_daily`, `read_weight`, `Config` and `rolling7`
- Produces:
  - `component_scores(df: pd.DataFrame, config: Config) -> pd.DataFrame`: a weekly index (Mondays) with columns `resting_hr`, `hrv`, `sleep` and `weight`, each a value from 0–100 or NaN
  - `health_index(scores: pd.DataFrame) -> pd.Series`: weekly, NaN when fewer than 3 components are available

- [ ] **Step 1: Write failing tests**
  - `test_score_50_when_equal_to_baseline`
  - `test_score_65_at_plus_one_sd`: for a "higher is better" metric, a 28-day mean one standard deviation above baseline scores 65
  - `test_lower_is_better_sign`: resting heart rate one standard deviation *below* baseline scores 65
  - `test_score_clamped`: +4 SD scores 100 and −4 SD scores 0
  - `test_sleep_band_distance`: a baseline of 6.5 h (0.5 h outside a 7–9 h band) and a current 28-day mean of 7.5 h (inside the band) score above 50
  - `test_weight_goal_maintain_penalises_drift_both_ways`: ±1 SD both score 35
  - `test_weight_goal_lose`: −1 SD scores 65
  - `test_index_needs_three_components`: 2 components give NaN, 3 give their mean (Review Focus 1)
  - `test_baseline_needs_60_days`: a history of 50 days gives NaN for every week (Review Focus 2)
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement it, following spec §8.2:**
  - the 28-day mean is compared with the median of the 180 days ending 28 days earlier
  - SD is the standard deviation of daily values over that baseline window
  - for the "closer is better" cases, z = (baseline distance − current distance) / SD
  - score = clamp(50 + 15·z, 0, 100)
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: personal health index"`.

### Task 9: Monthly report card, plus rendering the index and card

**Files:**
- Create: `hd/metrics/report_card.py`
- Modify: `hd/dashboard/build.py` (payload keys `"health_index"` and `"report_card"`), the template and `app.js`
- Test: `tests/test_report_card.py`, `tests/test_build.py` (new asserts)

**Interfaces:**
- Consumes: `health_index`, `component_scores`, `read_daily`, `read_weight` and `read_activities`
- Produces: `report_card(conn, config, months: int = 12) -> list[ReportRow]`
  - `ReportRow` has `month: str` ("2026-10") and `cells: dict[str, Literal["better","same","worse","not_enough_data"]]`
  - Metrics: `resting_hr`, `hrv`, `sleep`, `weight`, `steps` and `weekly_miles`

- [ ] **Step 1: Write failing tests**
  - `test_better_when_more_than_half_sd`: a month's resting heart rate mean 0.6 SD below the trailing 6-month baseline is `"better"`
  - `test_same_within_half_sd`
  - `test_not_enough_data_under_10_days`
  - `test_weight_uses_goal`
  - `test_build_has_index_and_report_card`: the ids `health-index` and `report-card` are present
  - `test_index_label_verbatim`
  - `test_index_shows_needs_more_history`: a fixture with 50 days of history renders "Needs more history" (Review Focus 2)
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `report_card.py` and render both:**
  - **Index:** the line goes at the top of the page, with 4 component sparklines and the label beneath it. For the 30 d and 90 d views the line shows the last 12 months.
  - **Report card:** sits inside Health trends as a table. Each cell shows a word plus a symbol (↑ better, → same, ↓ worse, – not enough data), never colour alone.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: monthly report card; render health index and card"`.

**CHECK-IN (Phase 4):** I review the index and report card against my own sense of the last year.
- **Acceptance:** nothing reads as a medical claim, and every component is visible.

---

## Phase 5: Recovery and Running

### Task 10: Recovery section

**Files:**
- Create: `hd/metrics/recovery.py`
- Modify: `build.py` (payload key `"recovery"`), the template and `app.js`
- Test: `tests/test_recovery.py`

**Interfaces:**
- Produces: `weekly_recovery(conn, start: date, end: date) -> pd.DataFrame`
  - Weekly index (Mondays). Columns: `load`, `load_source` (`"training_load"` or `"minutes"`), `hrv_7d`, `sleep_score`, `stress_avg` and `body_battery_high`.

- [ ] **Step 1: Write failing tests**
  - `test_weekly_load_sums_training_load`
  - `test_load_falls_back_to_minutes_when_training_load_missing`: `load_source == "minutes"`, and the chart's axis label reads "Activity minutes"
  - `test_week_with_no_activities_is_zero_load_not_nan` (a week with no workouts is real data)
  - `test_recovery_correlation_label_verbatim`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement it and render the section as in mockup A.** Show load bars with the HRV and sleep score lines on one week axis, plus a small stress and Body Battery chart. If the page shows a correlation coefficient between load and next-week HRV, put the label "Correlation, not cause." next to it.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: recovery section"`.

### Task 11: Running section

**Files:**
- Create: `hd/metrics/running.py`
- Modify: `build.py` (payload key `"running"`), the template and `app.js`
- Test: `tests/test_running.py`

**Interfaces:**
- Produces:
  - `RUN_TYPES: frozenset[str]` (set from the real layout; e.g. `running`, `treadmill_running`, `trail_running`)
  - `weekly_miles(conn, start, end) -> pd.Series` (weeks starting Monday)
  - `easy_pace(conn, config, start, end) -> pd.DataFrame`, with columns `date`, `pace_s_per_mi` and `rolling_median_8`
  - `latest_vo2(conn) -> tuple[date, float]|None`
  - `recent_runs(conn, n=10) -> list[dict]`
  - `median_kcal_per_mile(conn, end: date, days=90) -> tuple[float|None, int]`: the value and the number of runs it's based on (used by Task 12)

- [ ] **Step 1: Write failing tests**
  - `test_weekly_miles_runs_only`: a cycling activity is excluded
  - `test_easy_pace_filters_hr_band`: runs averaging 139, 145 and 151 bpm keep only the 145 run
  - `test_easy_pace_rolling_median_8`
  - `test_latest_vo2_with_as_of_date`
  - `test_median_kcal_per_mile`: run kcal per mile of 100, 110, 120, 130 and 140 give `(120.0, 5)`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement it and render the section.** Show weekly miles bars, easy-pace dots with the median line (axis "min/mile, lower = faster"), VO2 max with "as of <date>", and a recent-runs table that scrolls sideways on narrow screens.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: running section"`.

**CHECK-IN (Phase 5):** Run `hd build` on real data.
- **Acceptance:**
  - weekly miles and recent runs match Garmin Connect
  - the easy-pace band makes sense for me, or I change `easy_hr_band`

---

## Phase 6: Daily energy

### Task 12: Energy formula

**Files:**
- Create: `hd/metrics/energy.py`
- Test: `tests/test_energy.py`

**Interfaces:**
- Consumes: `read_daily`, `read_activities`, `read_profile`, the daily weight from Task 6, and `median_kcal_per_mile`
- Produces:
  - Constants: `NET_WALK_KCAL_PER_KG_KM = 0.50`, `TEF = 1.10`, `STRIDE_HEIGHT_FACTOR = 0.414` and `FALLBACK_RUN_KCAL_PER_KG_KM = 1.0`
  - `resting_kcal(weight_kg, height_cm, age_years, sex) -> float`
  - `daily_energy(conn, config, start, end) -> pd.DataFrame`, with columns `resting`, `steps`, `workouts`, `estimate` and `garmin_total`
  - `calculator_params(conn, config, today) -> dict|None`, with keys `weight_kg`, `resting`, `stride_m`, `run_kcal_per_mile`, `run_kcal_source` (`"own_runs"` or `"fallback"`) and `tef`. Returns `None` when the profile is incomplete.

- [ ] **Step 1: Write failing tests, using the worked example from spec §8.1.** The example is male, 180 cm, 40 years old, 75 kg.
  - `test_resting_mifflin`: `resting_kcal(75, 180, 40, "male") == 1680`, and the same inputs with `"female"` give 1514
  - `test_daily_estimate_worked_example`:
    - inputs: 10,000 steps, 1,000 of them during a workout, `distance_m = 7500` (stride 0.75 m), and one 45-minute activity of 500 kcal
    - expected parts: steps 253.125, workouts 447.5, and `estimate == pytest.approx(2618.69, abs=0.01)`
  - `test_stride_fallback_from_height`: with no distance, the stride is 180 × 0.414 / 100 = 0.7452 m
  - `test_weight_carried_forward`
  - `test_calculator_uses_own_runs_when_5_or_more`, and `test_calculator_fallback_under_5_runs`: the run cost is 1.0 × kg × 1.609344 kcal per mile, with `run_kcal_source == "fallback"`
  - `test_missing_profile_returns_none` (Review Focus 5)
  - `test_garmin_total_passthrough`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `energy.py` following spec §8.1 exactly.** Age is computed on each day from `birth_date`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: daily energy estimate"`.

### Task 13: Daily energy section and calculator

**Files:**
- Modify: `build.py` (payload keys `"energy"` and `"calculator"`), the template and `app.js`
- Test: `tests/test_build.py` (new asserts)

**Interfaces:**
- Consumes: `daily_energy` and `calculator_params`
- Produces: `estimateKcal(params, steps, runMiles)` in `app.js`. It mirrors §8.1:
  - `(params.resting + steps*params.stride_m/1000*params.weight_kg*0.5 + runMiles*(params.run_kcal_per_mile - params.resting/1440*minutesPerMile)) * params.tef`
  - `minutesPerMile` is the median run pace from the payload. If there is none, use 10.

- [ ] **Step 1: Write failing tests**
  - `test_build_has_energy_section`
  - `test_energy_label_verbatim`
  - `test_calculator_params_in_payload`
  - `test_energy_section_message_when_profile_missing`: renders "Add height_cm, birth_date and sex to config.toml to see energy estimates" (Review Focus 5)
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement the section:**
  - per-day estimate bars, with Garmin's total as a line
  - clicking a day shows its breakdown (resting / steps / workouts / digestion)
  - a calculator with a labelled `<input type="number">` for steps and one for run miles, defaulting to today's values, and showing the result live
    - the steps input is labelled "Steps (not counting runs)", so run steps aren't counted twice
  - the label next to it
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: daily energy section and calculator"`.

**CHECK-IN (Phase 6):** In the browser, the calculator with 10,000 steps and 0 miles should match the Python `daily_energy` value for a no-workout day with 10,000 steps, within 1 kcal. This is a manual parity check, because there is no automated JS test runner.
- **Acceptance:** I find the numbers plausible next to Garmin's total.

---

## Phase 7: Garmin Personal API daily refresh

### Task 14: API probe (verify coverage before parsing)

**Files:**
- Create: `hd/sources/garmin_api.py` (token and probe only), `.env.example`
- Modify: `hd/cli.py` (`api-probe`)
- Test: `tests/test_garmin_api.py`

**Interfaces:**
- Produces:
  - `get_token(client: httpx.Client, api_key: str) -> str`:
    - POST `https://personal.connectapi.garmin.com/personalapitoken-service/personal-api/personal-api-key/token`
    - header `Authorization: ApiKey <key>`
  - `probe(client, token, day: date) -> list[ProbeResult]`, where `ProbeResult` has `endpoint`, `status:int` and `field_names: list[str]`

- [ ] **Step 0 (me, on the Mac):**
  1. Create a Personal API key in Garmin Connect web: Settings → Personal API Key → 1-year expiry.
  2. Copy `.env.example` to `.env`.
  3. Paste the key into `.env` myself. It never goes into the chat.
- [ ] **Step 1: Write failing tests, using `httpx.MockTransport`**
  - `test_get_token_sends_apikey_header`
  - `test_get_token_401_raises_KeyInvalid`
  - `test_probe_reports_field_names_not_values`
  - `test_key_never_in_output`: the key string doesn't appear in captured stdout or stderr
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `get_token` and `probe`.**
  - The endpoint list comes from Garmin's Personal API Swagger page, which I open in my browser and save as `docs/personal-api-endpoints.md` (paths only).
  - `hd api-probe` calls each endpoint for yesterday and writes `data/api_probe.json` with field names only.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: Personal API token and probe"`.

**CHECK-IN (Phase 7a):** Run `uv run hd api-probe`. Show me which endpoints respond and which fields they expose.
- **Acceptance:** we agree on the endpoint→record mapping, and on which metrics stay export-only (expected: VO2 max), before Task 15 begins.

### Task 15: API pull and normalisation

**Files:**
- Modify: `hd/sources/garmin_api.py`
- Test: `tests/test_garmin_api.py`, with fixtures `tests/fixtures/api/*.json` that use the probed field names and fake values

**Interfaces:**
- Produces: `fetch_recent(api_key: str, days: int = 7, today: date|None = None) -> FetchResult`
  - `FetchResult` has `records: list[Record]`, `fetched: dict[str,int]` and `error: str|None`
  - Exceptions: `KeyInvalid`, `RateLimited`

- [ ] **Step 1: Write failing tests**
  - `test_api_daily_normalises_like_export`: the same fake day from the API and from the export gives an equal `DailyRecord`, apart from `source`
  - `test_api_activity_local_date`
  - `test_429_stops_and_returns_partial_with_error`: no retries beyond one backoff of 30 s, and the sleep is patched out in the test
  - `test_network_error_returns_error_not_raise`
  - `test_401_raises_KeyInvalid` (Review Focus 4)
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `fetch_recent` using the agreed mapping.** Requests are sequential, at most one per endpoint per day in the range.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: Personal API fetch and normalisation"`.

### Task 16: `hd refresh` and README

**Files:**
- Modify: `hd/cli.py`, `README.md`
- Test: `tests/test_refresh.py`

**Interfaces:**
- Consumes: `fetch_recent`, `upsert`, `flag_implausible` and `build_dashboard`
- Produces: `refresh(config, today=None, open_browser=True) -> int` (exit code)

- [ ] **Step 1: Write failing tests**
  - `test_refresh_upserts_and_builds`
  - `test_refresh_offline_still_builds_and_exits_0`: prints "Couldn't reach Garmin; showing stored data up to <date>" (Review Focus 4)
  - `test_refresh_expired_key_message`: prints "create a new key in Garmin Connect settings and update .env", rebuilds, and exits 0
  - `test_refresh_missing_env_key_message`
- [ ] **Step 2: Run the tests.** Expected: FAIL.
- [ ] **Step 3: Implement `refresh`.** It loads `.env`, fetches 7 days, upserts in one transaction, flags implausible values, builds, opens the page, and prints what was fetched.

  Then write the README. Keep it short, with these sections:
  - Setup: `brew install uv`, then `uv sync`
  - First import: `hd inventory`, then `hd import-export`
  - Daily: `hd refresh`
  - Personal API key: create, store in `.env`, renew before it expires
  - A new export for VO2 max history
  - Settings in `config.toml`
  - Privacy: what lives where
- [ ] **Step 4: Run `uv run pytest -q`.** Expected: all PASS.
- [ ] **Step 5: Commit** with `git commit -m "feat: hd refresh end-to-end; README"`.

**CHECK-IN (Phase 7, final):** Run `uv run hd refresh` on the Mac.
- **Acceptance:**
  - yesterday's data appears without a new export
  - running it again is a no-op
  - turning off Wi-Fi gives the friendly offline message and the page still opens
  - `git status` shows no data, `.env` or database files
