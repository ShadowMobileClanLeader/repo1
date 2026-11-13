# Personal Health Dashboard — Design Spec

- **Date:** 2026-11-13
- **Status:** Draft for review
- **Mockup (layout A):** private canvas, "Health dashboard layout mockups", board "A · Calm health report"

## 1. Purpose

A calm, private health dashboard built from my own Garmin data. It runs on my Mac and opens in my browser. It reads like a health report, not a training-analytics tool, and answers three questions at a glance:

1. Am I generally healthier than 3, 6 or 12 months ago?
2. Am I recovering well, or wearing myself down?
3. Is my running improving?

It also estimates how many calories a given day needed, based mainly on steps.

## 2. Scope

**In scope**

- Garmin data only. History comes from the full-account export ZIP. Daily refresh comes from the official Garmin Personal API.
- One person, one Garmin account, one Mac.
- Imperial display units: lb, miles, min/mile, °F, kcal.
- Time ranges: 90 days by default, with 30 days, 1 year and all-time toggles.

**Out of scope**

- Cronometer and any other nutrition logging. Removed by decision on 2026-11-13.
- Unofficial Garmin libraries, such as `python-garminconnect`.
- Hosting, phone access, or sharing with anyone.
- Race predictions, training plans, and coaching advice.
- Medical interpretation of any kind.

**Possible later additions (not planned)**

- An MCP server over the local database, for asking Claude questions about the data.
- Manual daily tags, such as "sick", "travel" or "alcohol".

## 3. Data sources and access

| Source | Used for | Access | Account risk |
|---|---|---|---|
| Garmin full-account export ZIP | All history. VO2 max over time. Profile data (height, birth date, sex), if present. | I request it from Garmin's "Export Your Data" page and run `hd import-export <zip>`. | None |
| Garmin Personal API (official, launched October 2026) | Daily refresh of health summaries (sleep, HRV, heart rate, stress, Body Battery, weight, steps, calories) and activities. | An API key I create in Garmin Connect web settings and store in `.env`. The key is exchanged for a 24-hour token on each run. | Low. The API is sanctioned for personal use. |

**Known gaps and the rules for handling them**

- **VO2 max may be missing from the Personal API.** Third-party reports say it isn't included. VO2 max therefore updates only when I import a fresh export. The dashboard shows the date of the latest value.
- **The Personal API's endpoint list hasn't been verified.** Garmin's Swagger page needs a browser. The first API build phase must list the endpoints actually available to my key, and adjust the mapping before writing any parsing code.
- **The layout of my export hasn't been inspected yet.** Build phase 1 starts with a read-only inventory of the ZIP: file types, date range and metrics. The importer is written against what is actually in it.

MCP connectors are not used for ingestion. They are built for chat, not scheduled data pulls, and no official Garmin MCP server exists.

## 4. Architecture

```
Garmin export ZIP ──► sources/garmin_export ─┐
                                              ├─► store (SQLite: data/health.db) ─► metrics/* ─► dashboard/build ─► out/dashboard.html
Garmin Personal API ─► sources/garmin_api ───┘                                                     (self-contained, opened in browser)
```

- **Language:** Python 3.12, managed with `uv`. Garmin tooling and data libraries are strongest in Python, and `uv` gives one-command setup on macOS.
- **Storage:** a single SQLite file, `data/health.db`. It needs no server, holds years of daily rows easily, and supports idempotent upserts.
- **Transformation:** plain Python functions over SQLite queries, with pandas for rolling windows and resampling. The data is small (thousands of rows), so nothing heavier is needed.
- **Visualisation:**
  - A Jinja2 template renders one self-contained HTML file. Data is embedded as JSON, and Observable Plot and d3 are vendored into the repo.
  - Viewing it makes **no network calls** and needs no server.
  - Range toggles and the calorie calculator are a small amount of vanilla JS.
- **Commands** (one `hd` CLI):
  - `hd import-export <zip>` copies the ZIP into `data/raw/` (the original is never modified), then imports it.
  - `hd refresh` pulls the last 7 days from the Personal API, rebuilds the page and opens it. If the API is unavailable, it still rebuilds from stored data and says so.
  - `hd build` rebuilds the page from the database only.
  - `hd inventory <zip>` prints a read-only summary of an export.

### Units of the codebase (one purpose each)

| Module | Does | Depends on |
|---|---|---|
| `hd/sources/garmin_export.py` | Parses export files into normalised records | Nothing project-specific |
| `hd/sources/garmin_api.py` | Gets a token, pulls date ranges, normalises records into the same shape as the export | `httpx`, `.env` |
| `hd/store.py` | Schema creation, upserts and simple reads | `sqlite3` |
| `hd/units.py` | SI ↔ imperial conversion, used only at display time | Nothing |
| `hd/metrics/daily.py` | Rolling averages with minimum-data rules | `store` |
| `hd/metrics/energy.py` | Daily energy estimate and calculator constants | `store`, profile |
| `hd/metrics/health_index.py` | Health trend line and per-metric scores | `daily` |
| `hd/metrics/report_card.py` | Monthly better / same / worse grid | `daily` |
| `hd/metrics/running.py` | Weekly miles, easy pace at heart rate, recent runs | `store` |
| `hd/dashboard/build.py` | Assembles the metrics into JSON and renders the template | `metrics/*` |
| `hd/cli.py` | The commands above | All of the above |

## 5. Data model (SQLite, SI units)

- **`daily`**: one row per local calendar date, keyed by `date`.
  - Fields: `steps`, `distance_m`, `resting_hr`, `hrv_night_ms`, `sleep_s`, `sleep_score`, `stress_avg`, `body_battery_high`, `body_battery_low`, `kcal_total_garmin`, `kcal_active_garmin`, `kcal_bmr_garmin`, `source`, `updated_at`.
- **`weight`**: keyed by `date` (local). Fields: `weight_kg`, `body_fat_pct`, `source`.
- **`activities`**: keyed by `activity_id`.
  - Fields: `start_utc`, `local_date`, `type`, `distance_m`, `duration_s`, `avg_hr`, `max_hr`, `kcal`, `steps`, `elev_gain_m`, `training_load`, `source`.
- **`vo2max`**: keyed by `date` and `sport`. Field: `value`.
- **`profile`**: key/value pairs (`height_cm`, `birth_date`, `sex`).
  - Filled from the export if present, otherwise from `config.toml`.
  - Values in `config.toml` always win.

## 6. Data handling rules

- **Day key:** the device's local calendar date, as Garmin reports it (`calendarDate`). Activities use their local start date. Timestamps are stored in UTC alongside local dates, so a day in another timezone stays that day.
- **Duplicates:** every import is an upsert on the natural key.
  - Re-importing the same export changes nothing.
  - A newer source overwrites older values field by field, but **never replaces a known value with an empty one**.
- **Gaps:**
  - Missing days stay missing, never zero, and charts draw them as breaks.
  - A rolling 7-day average needs at least 4 days of data, otherwise it's blank.
  - Steps of 0, with no heart-rate data that day, count as "not worn".
- **Units:** stored in metric, converted to imperial only at render time, all in `units.py`.
- **Implausible values** (for example resting heart rate below 25 or above 120, or a weight jump of more than 10 lb in one day): kept in the database but flagged and left out of averages and the health index. The build prints how many were excluded.

## 7. Dashboard layout (mockup A, updated)

Top to bottom, one scrolling page, light and dark mode, a tooltip on every chart:

1. **Header:** title, the date each source last updated, the range toggle (30 d / **90 d** / 1 y / All), and a reminder to run `hd refresh`.
2. **Health trend line:** one 0–100 line over the selected range (or the last 12 months for the 30 d and 90 d views). Small component sparklines sit underneath, and a note says what it is (section 8.2).
3. **Headline tiles:** resting heart rate, overnight HRV, sleep (7-day average) and weight (7-day average). Each shows the change versus 90 days ago.
4. **Health trends:**
   - charts for resting heart rate, HRV (with my usual range shaded), sleep and weight
   - the **monthly report card** (section 8.3)
   - a short "talk to a doctor" note
5. **Recovery:** weekly training load bars against 7-day HRV and sleep score lines, plus stress and Body Battery. Any correlation shown is labelled "correlation, not cause".
6. **Daily energy** (replaces the nutrition strip):
   - per-day estimated calories needed, with Garmin's own total alongside
   - the breakdown of the selected day: resting + steps + workouts + digestion
   - a **calculator**: enter steps (and optionally run miles) to see the estimated calories at my current weight
7. **Running:** weekly miles, easy-run pace at 140–150 bpm (min/mile), VO2 max (with the "as of" date) and recent runs.
8. **Footer:** a neutral note: "trends and correlations from my own data, not diagnoses; talk to a doctor about health concerns."

## 8. Calculations

### 8.1 Daily energy estimate

```
estimate = (resting + steps + workouts) × 1.10
```

**resting:** Mifflin-St Jeor resting metabolic rate:

```
10·kg + 6.25·cm − 5·age + s     (s = +5 male, −161 female)
```

- Weight is the 7-day average from `weight`, carried forward if there's no weigh-in.
- Height, age and sex come from `profile`.

**steps:** net walking cost for steps taken outside recorded workouts:

```
(steps − workout_steps) × stride_m / 1000 × kg × 0.50
```

- 0.50 is net kcal per kg per km on flat ground.
- `stride_m` is the day's Garmin `distance_m / steps` when available. Otherwise it falls back to height × 0.414.

**workouts:** net workout calories:

```
Σ activity.kcal − resting/1440 × activity minutes
```

- Garmin's activity calories are gross, so the resting share for those minutes is subtracted to avoid counting it twice.

**× 1.10:** the thermic effect of food, about 10% of intake.

**Calculator:** uses the same formula, with today's weight.
- Run calories are my own median kcal per mile from the last 90 days of runs.
- With fewer than 5 runs, it falls back to 1.0 kcal per kg per km.

**Shown with it:** "Estimate, typically within ±10–20% for an individual. Not dietary advice." Garmin's own daily total sits alongside for comparison.

**Why this formula:**
- Mifflin-St Jeor is the most reliable common resting-rate equation (within ±10% for most adults in validation studies), but it can miss by more than that for an individual.
- Net walking cost of about 0.5 kcal/kg/km is the commonly cited figure. Gross figures are 0.7–1.0.

### 8.2 Health trend line (personal index, 0–100)

**Components:** resting heart rate (lower is better), overnight HRV (higher is better), sleep duration, and weight.
- **Sleep:** better as it gets closer to the target band in `config.toml`, default 7–9 h.
- **Weight:** depends on the `weight_goal` setting: `maintain` (default; closer to baseline is better), `lose`, or `gain`.

**Method:**
1. For each component, take the 28-day mean.
2. Compare it with my personal baseline: the median of the 180 days ending 28 days earlier.
3. Scale by my own day-to-day spread: z = (mean − baseline) / standard deviation, with the sign set so that "better" is positive.
   - For the "closer is better" cases (sleep against its band, weight on `maintain`), use the distance instead: z = (baseline distance − current distance) / standard deviation. Here distance is how far the value is from the band or the baseline, and 0 means inside the band.
4. Component score = clamp(50 + 15·z, 0, 100).
5. The index is the mean of the available component scores, computed weekly.
6. It needs at least 3 of the 4 components; otherwise there's a gap.

50 means "same as my recent normal."

It's always labelled "personal index from your own data, not a medical score." The component sparklines are always shown, so it's never a black box.

### 8.3 Monthly report card

- One row per month, one column per metric: resting heart rate, HRV, sleep, weight, steps, and weekly miles.
- Each cell compares the month's mean with the trailing 6-month baseline: **better**, **about the same** (within 0.5 standard deviations), or **worse**. Words and symbols are used, never colour alone.
- Months with fewer than 10 days of data show "not enough data."

### 8.4 Running

- **Weekly miles:** running-type activities only, with weeks starting Monday.
- **Easy pace at heart rate:** runs with an average heart rate of 140–150 bpm (the band can be changed in config). The chart shows a pace dot per run and a rolling median of 8 runs.
- **VO2 max:** the latest value per date from the export.
- **Recent runs:** the last 10 runs.

## 9. Privacy and security

- All data stays on my Mac. There is no hosting and no third-party services.
- The dashboard page makes no network requests, because all libraries are vendored.
- `.gitignore` covers `.env`, `data/`, `out/` and `*.db`. It is committed **before** any of those exist.
- The Garmin API key lives only in `.env`, which I type myself. It is never pasted into the chat, logged or printed.
- The original export is read-only. It's copied into `data/raw/` and the copy is what gets imported.
- Tests use synthetic fixtures only. No real health data is committed.

## 10. Health content rules

- Trends and correlations only. No diagnoses, treatment or dietary advice.
- Anything that could read as medical gets a short neutral "talk to a doctor if this worries you" note.
- Correlations are labelled as correlations, never as causes.
- Calorie figures are labelled as estimates with their error range.

## 11. Error handling

- **Import:** an unknown file or field is skipped with a count in the summary, never a crash. The import as a whole runs in one transaction.
- **API:**
  - a 401 response means the key has expired or is invalid. The message is "create a new key in Garmin Connect settings and update `.env`."
  - a 429 response or a network error means back off and stop, then rebuild from stored data.
  - every run prints what was fetched.
- **Build:** a section with no data shows "no data yet" rather than an empty chart.

## 12. Testing

- `pytest` with small synthetic fixtures that mimic the export and API shapes. They are created in phase 1 from the inventory's structure, using fake values only.
- Unit tests cover:
  - units conversion
  - upsert precedence (never overwrite a value with an empty one)
  - timezone and day keys
  - gap rules
  - the energy formula, with worked examples
  - health index scaling
  - report card thresholds
- Build smoke test: `hd build` on fixtures produces HTML containing every section, and the page makes no external requests (checked with headless Chromium).
- Each build phase ends with a real run on my data on my Mac and a look at the page.

## 13. To confirm during the build

1. Which endpoints and fields my Personal API key actually exposes (the API build phase).
2. My export's real layout, and whether profile data (height, birth date, sex) is in it. If not, I fill them in `config.toml`.
3. The `weight_goal` setting and sleep target band, which I set in `config.toml`.
