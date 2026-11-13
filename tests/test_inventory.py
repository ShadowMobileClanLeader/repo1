import hashlib
from datetime import date

from hd.inventory import format_report, inventory
from tests.fixtures.make_export import SENTINEL_RHR, make_export


def test_inventory_counts_files_by_extension(tmp_path):
    report = inventory(make_export(tmp_path))
    assert report.files_by_ext == {".json": 5, ".zip": 1}


def test_inventory_detects_date_range(tmp_path):
    report = inventory(make_export(tmp_path))
    uds = next(f for f in report.json_files if "UDSFile" in f.path)
    assert uds.date_min == date(2026, 1, 1)
    assert uds.date_max == date(2026, 4, 10)
    assert uds.n_records == 100


def test_inventory_detects_metrics(tmp_path):
    report = inventory(make_export(tmp_path))
    for metric in ["steps", "resting_hr", "sleep", "activities", "vo2max"]:
        assert report.metrics_detected[metric] is not None, metric
    assert report.metrics_detected["hrv"] is None
    assert report.metrics_detected["activities"].start == date(2026, 1, 1)


def test_inventory_does_not_modify_zip(tmp_path):
    path = make_export(tmp_path)
    before = hashlib.sha256(path.read_bytes()).hexdigest()
    inventory(path)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before


def test_inventory_never_prints_values(tmp_path):
    text = format_report(inventory(make_export(tmp_path)))
    assert "restingHeartRate" in text  # key names are fine
    assert str(SENTINEL_RHR) not in text  # values are not
    assert "fake-user" not in text
    assert "1986" not in text  # birth date is a value, not a data range


def test_cli_inventory_prints_report(tmp_path, capsys):
    from hd.cli import main

    assert main(["inventory", str(make_export(tmp_path))]) == 0
    assert "resting_hr" in capsys.readouterr().out
