"""Read-only summary of a Garmin export ZIP.

Opens the ZIP for reading only and never extracts it. The report contains
file and key names, counts and date ranges — never health values.
"""

from __future__ import annotations

import json
import zipfile
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path, PurePosixPath

# Keys whose values say *when* a record happened (matched case-insensitively).
DATE_KEYS = {"calendardate", "starttimelocal", "starttimegmt", "date"}

# metric name -> predicate on a lower-cased key name
METRIC_KEYS: dict[str, tuple[str, ...]] = {
    "steps": ("totalsteps",),
    "resting_hr": ("restingheartrate",),
    "sleep": ("sleep",),
    "hrv": ("hrv", "lastnightavg"),
    "weight": ("weight",),
    "activities": ("activityid",),
    "vo2max": ("vo2maxvalue", "maxmet"),
    "stress": ("averagestresslevel",),
}

_EARLIEST = datetime(2000, 1, 1, tzinfo=timezone.utc)


@dataclass(frozen=True)
class DateRange:
    start: date | None
    end: date | None


@dataclass
class JsonFileInfo:
    path: str
    n_records: int
    top_level_keys: list[str]
    date_min: date | None
    date_max: date | None
    parse_error: bool = False


@dataclass
class InventoryReport:
    zip_name: str
    files_by_ext: dict[str, int]
    folders: dict[str, int]
    json_files: list[JsonFileInfo]
    metrics_detected: dict[str, DateRange | None] = field(default_factory=dict)


def _to_date(value) -> date | None:
    """Interpret an ISO string or epoch-milliseconds number as a date."""
    latest = datetime.now(timezone.utc) + timedelta(days=2)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            dt = datetime.fromtimestamp(value / 1000, tz=timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
        return dt.date() if _EARLIEST <= dt <= latest else None
    if isinstance(value, str) and len(value) >= 10:
        try:
            d = date.fromisoformat(value[:10])
        except ValueError:
            return None
        return d if _EARLIEST.date() <= d <= latest.date() else None
    if isinstance(value, dict):  # e.g. {"date": "..."}
        for v in value.values():
            d = _to_date(v)
            if d:
                return d
    return None


def _record_dates(rec: dict) -> list[date]:
    out = []
    for k, v in rec.items():
        if k.lower() in DATE_KEYS:
            d = _to_date(v)
            if d:
                out.append(d)
    return out


def _iter_records(obj):
    """Yield the dicts that look like data records (they carry a date key).

    Garmin files are lists of records, sometimes wrapped one or two levels deep
    (e.g. [{"summarizedActivitiesExport": [...]}]).
    """
    if isinstance(obj, dict):
        if any(k.lower() in DATE_KEYS for k in obj):
            yield obj
            return
        for v in obj.values():
            if isinstance(v, (list, dict)):
                yield from _iter_records(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from _iter_records(item)


def _metrics_for_keys(keys: set[str], path: str) -> set[str]:
    lower = {k.lower() for k in keys}
    found = set()
    for metric, needles in METRIC_KEYS.items():
        if any(n in k for k in lower for n in needles):
            found.add(metric)
    if "sleep" in path.lower():
        found.add("sleep")
    return found


def inventory(zip_path: Path) -> InventoryReport:
    ext_counts: Counter[str] = Counter()
    folder_counts: Counter[str] = Counter()
    json_files: list[JsonFileInfo] = []
    metric_ranges: dict[str, list[date]] = {m: [] for m in METRIC_KEYS}
    metric_seen: set[str] = set()

    with zipfile.ZipFile(zip_path, "r") as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            p = PurePosixPath(info.filename)
            ext_counts[p.suffix.lower() or "(none)"] += 1
            folder_counts[str(PurePosixPath(*p.parts[:2])) if len(p.parts) > 2 else str(p.parent)] += 1
            if p.suffix.lower() != ".json":
                continue
            try:
                data = json.loads(zf.read(info))
            except (json.JSONDecodeError, UnicodeDecodeError):
                json_files.append(JsonFileInfo(info.filename, 0, [], None, None, parse_error=True))
                continue

            records = list(_iter_records(data))
            if not records and isinstance(data, dict):
                records_for_keys = [data]  # e.g. a profile file: no dates, still show keys
            else:
                records_for_keys = records
            keys: set[str] = set()
            for r in records_for_keys:
                keys.update(r.keys())
            dates = [d for r in records for d in _record_dates(r)]

            json_files.append(
                JsonFileInfo(
                    path=info.filename,
                    n_records=len(records),
                    top_level_keys=sorted(keys),
                    date_min=min(dates) if dates else None,
                    date_max=max(dates) if dates else None,
                )
            )
            for metric in _metrics_for_keys(keys, info.filename):
                metric_seen.add(metric)
                metric_ranges[metric].extend(dates)

    detected: dict[str, DateRange | None] = {}
    for metric, ds in metric_ranges.items():
        if metric not in metric_seen:
            detected[metric] = None
        else:
            detected[metric] = DateRange(min(ds), max(ds)) if ds else DateRange(None, None)

    return InventoryReport(
        zip_name=Path(zip_path).name,
        files_by_ext=dict(ext_counts),
        folders=dict(sorted(folder_counts.items())),
        json_files=json_files,
        metrics_detected=detected,
    )


def _fmt_range(start: date | None, end: date | None) -> str:
    if start is None:
        return "no dates found"
    return f"{start.isoformat()} → {end.isoformat()}"


def format_report(r: InventoryReport) -> str:
    """Human-readable report: names, counts and date ranges only."""
    lines = [f"Garmin export inventory: {r.zip_name}", ""]
    total = sum(r.files_by_ext.values())
    lines.append(f"Files: {total}")
    for ext, n in sorted(r.files_by_ext.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {ext:<8} {n}")
    lines += ["", "Folders:"]
    for folder, n in r.folders.items():
        lines.append(f"  {folder}  ({n} files)")

    all_dates = [d for f in r.json_files for d in (f.date_min, f.date_max) if d]
    lines += ["", "Overall date range: " + (_fmt_range(min(all_dates), max(all_dates)) if all_dates else "none found")]

    lines += ["", "Metrics:"]
    for metric, rng in r.metrics_detected.items():
        status = "not found" if rng is None else _fmt_range(rng.start, rng.end)
        lines.append(f"  {metric:<11} {status}")

    lines += ["", "JSON files (records, date range, keys):"]
    for f in r.json_files:
        if f.parse_error:
            lines.append(f"  {f.path}: could not parse")
            continue
        lines.append(f"  {f.path}")
        lines.append(f"    records: {f.n_records}   dates: {_fmt_range(f.date_min, f.date_max)}")
        lines.append(f"    keys: {', '.join(f.top_level_keys) if f.top_level_keys else '(none)'}")
    lines += ["", "No health values were printed. The ZIP was opened read-only."]
    return "\n".join(lines)
