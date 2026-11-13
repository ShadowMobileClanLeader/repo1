"""The `hd` command line."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SUBCOMMANDS = {
    "inventory": "Print a read-only summary of a Garmin export ZIP",
    "import-export": "Copy a Garmin export into data/raw and import it",
    "build": "Rebuild the dashboard from stored data",
    "refresh": "Pull recent data from the Garmin Personal API and rebuild",
    "api-probe": "List which Personal API endpoints and fields your key exposes",
}


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="hd", description="Private, local health dashboard.")
    sub = p.add_subparsers(dest="command", required=True)
    for name, help_text in SUBCOMMANDS.items():
        sp = sub.add_parser(name, help=help_text)
        if name in ("inventory", "import-export"):
            sp.add_argument("zip_path", type=Path, help="Path to the Garmin export ZIP")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    print(f"hd {args.command}: not implemented yet", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
