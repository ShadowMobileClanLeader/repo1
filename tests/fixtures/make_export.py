"""Build a small, entirely fake Garmin export ZIP for tests.

The layout follows what Garmin full-account exports usually look like. It is
expected, not confirmed: Task 4 updates it to match docs/export-layout.md.
All values are invented.
"""

from __future__ import annotations

import io
import json
import zipfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

START = date(2026, 1, 1)
END = date(2026, 4, 10)
# A distinctive fake value used to check that reports never print health values.
SENTINEL_RHR = 173
SENTINEL_DAY = date(2026, 2, 14)


def _days():
    d = START
    while d <= END:
        yield d
        d += timedelta(days=1)


def _epoch_ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def _uds() -> list[dict]:
    rows = []
    for i, d in enumerate(_days()):
        rows.append(
            {
                "calendarDate": d.isoformat(),
                "totalSteps": 8000 + (i % 7) * 500,
                "restingHeartRate": SENTINEL_RHR if d == SENTINEL_DAY else 47 + i % 6,
                "totalKilocalories": 2400.0 + (i % 5) * 50,
                "activeKilocalories": 600.0 + (i % 5) * 50,
                "bmrKilocalories": 1800.0,
                "totalDistanceMeters": 6000 + (i % 7) * 380,
                "averageStressLevel": 25 + i % 10,
                "bodyBatteryHighestValue": 80 + i % 15,
                "bodyBatteryLowestValue": 15 + i % 10,
            }
        )
    return rows


def _sleep() -> list[dict]:
    return [
        {
            "calendarDate": d.isoformat(),
            "sleepStartTimestampGMT": f"{(d - timedelta(days=1)).isoformat()}T23:00:00.0",
            "deepSleepSeconds": 5400,
            "lightSleepSeconds": 14400,
            "remSleepSeconds": 5400,
            "awakeSleepSeconds": 900,
            "sleepScores": {"overallScore": 70 + i % 20},
        }
        for i, d in enumerate(_days())
    ]


def _activities() -> list[dict]:
    acts = []
    for i, d in enumerate(_days()):
        if i % 3:
            continue
        start = datetime(d.year, d.month, d.day, 15, 0, tzinfo=timezone.utc)
        acts.append(
            {
                "activityId": 10_000_000 + i,
                "name": "Fake Run",
                "activityType": "running",
                "startTimeGmt": _epoch_ms(start),
                "startTimeLocal": _epoch_ms(start - timedelta(hours=8)),
                "distance": 800_000.0,  # centimetres in real exports (to confirm)
                "duration": 2_700_000.0,  # milliseconds
                "avgHr": 140 + i % 15,
                "calories": 500.0,
            }
        )
    return [{"summarizedActivitiesExport": acts}]


def _vo2() -> list[dict]:
    return [
        {"calendarDate": "2026-01-15", "vo2MaxValue": 49.0, "sport": "RUNNING"},
        {"calendarDate": "2026-03-20", "vo2MaxValue": 50.0, "sport": "RUNNING"},
    ]


def _profile() -> dict:
    return {"userName": "fake-user", "birthDate": "1986-04-02", "gender": "MALE", "height": 180.0}


def _nested_fit_zip() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("fake_activity.fit", b"\x0e\x10fake-fit-bytes")
    return buf.getvalue()


def make_export(tmp_path: Path) -> Path:
    """Write the fake export ZIP into tmp_path and return its path."""
    path = tmp_path / "garmin_export_fake.zip"
    base = "DI_CONNECT"
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{base}/DI-Connect-Aggregator/UDSFile_2026-01-01_2026-04-10.json", json.dumps(_uds()))
        z.writestr(f"{base}/DI-Connect-Wellness/2026-01-01_2026-04-10_sleepData.json", json.dumps(_sleep()))
        z.writestr(f"{base}/DI-Connect-Fitness/user_summarizedActivities.json", json.dumps(_activities()))
        z.writestr(f"{base}/DI-Connect-Metrics/MetricsMaxMetData_20260101_20260410.json", json.dumps(_vo2()))
        z.writestr(f"{base}/DI-Connect-User/user_profile.json", json.dumps(_profile()))
        z.writestr(f"{base}/DI-Connect-Uploaded-Files/UploadedFiles_0-_Part1.zip", _nested_fit_zip())
    return path
