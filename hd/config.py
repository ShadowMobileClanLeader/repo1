"""Load user settings from config.toml, falling back to defaults."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Literal

WEIGHT_GOALS = ("maintain", "lose", "gain")
SEXES = ("male", "female")


@dataclass(frozen=True)
class Config:
    height_cm: float | None = None
    birth_date: date | None = None
    sex: Literal["male", "female"] | None = None
    weight_goal: Literal["maintain", "lose", "gain"] = "maintain"
    sleep_band_h: tuple[float, float] = (7, 9)
    easy_hr_band: tuple[int, int] = (140, 150)
    db_path: Path = Path("data/health.db")
    out_path: Path = Path("out/dashboard.html")


def load_config(path: Path = Path("config.toml")) -> Config:
    """Read config.toml if it exists; missing keys use defaults."""
    if not path.exists():
        return Config()
    raw = tomllib.loads(path.read_text())

    weight_goal = raw.get("weight_goal", "maintain")
    if weight_goal not in WEIGHT_GOALS:
        raise ValueError(f"weight_goal must be one of {WEIGHT_GOALS}, got {weight_goal!r}")
    sex = raw.get("sex")
    if sex is not None and sex not in SEXES:
        raise ValueError(f"sex must be one of {SEXES}, got {sex!r}")

    kwargs = {
        "height_cm": raw.get("height_cm"),
        "birth_date": raw.get("birth_date"),
        "sex": sex,
        "weight_goal": weight_goal,
    }
    if "sleep_band_h" in raw:
        kwargs["sleep_band_h"] = tuple(raw["sleep_band_h"])
    if "easy_hr_band" in raw:
        kwargs["easy_hr_band"] = tuple(raw["easy_hr_band"])
    if "db_path" in raw:
        kwargs["db_path"] = Path(raw["db_path"])
    if "out_path" in raw:
        kwargs["out_path"] = Path(raw["out_path"])
    return Config(**kwargs)
