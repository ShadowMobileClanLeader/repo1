from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_gitignore_covers_private_paths():
    lines = {line.strip() for line in (ROOT / ".gitignore").read_text().splitlines()}
    for entry in [".env", "data/", "out/", "*.db", "config.toml"]:
        assert entry in lines, f"{entry} missing from .gitignore"
