from datetime import date

import pytest

from hd.config import load_config


def test_config_defaults_when_file_missing(tmp_path):
    cfg = load_config(tmp_path / "none.toml")
    assert cfg.weight_goal == "maintain"
    assert cfg.sleep_band_h == (7, 9)
    assert cfg.easy_hr_band == (140, 150)
    assert cfg.height_cm is None


def test_config_reads_profile(tmp_path):
    p = tmp_path / "config.toml"
    p.write_text('height_cm = 180\nbirth_date = 1986-04-02\nsex = "male"\n')
    cfg = load_config(p)
    assert cfg.height_cm == 180
    assert cfg.birth_date == date(1986, 4, 2)
    assert cfg.sex == "male"


def test_config_rejects_bad_weight_goal(tmp_path):
    p = tmp_path / "config.toml"
    p.write_text('weight_goal = "bulk"\n')
    with pytest.raises(ValueError):
        load_config(p)
