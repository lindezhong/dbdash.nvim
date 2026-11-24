"""Validate example/*.yaml against example/dbdash.schema.yaml (dev-only, needs jsonschema).

Usage: python3 -I tests/examples_schema.py [file.yaml ...]   -> exit 1 on errors.
"""
import pathlib
import sys

import jsonschema
import yaml

root = pathlib.Path(__file__).resolve().parent.parent / "example"
# UTF-8 explicitly: the files contain non-ASCII text and Windows defaults to the locale's codec.
schema = yaml.safe_load((root / "dbdash.schema.yaml").read_text(encoding="utf-8"))
jsonschema.Draft7Validator.check_schema(schema)
validator = jsonschema.Draft7Validator(schema)

files = [pathlib.Path(f) for f in sys.argv[1:]] or sorted(p for p in root.glob("*.yaml") if not p.name.endswith(".schema.yaml"))
bad = 0
for f in files:
    errors = sorted(validator.iter_errors(yaml.safe_load(f.read_text(encoding="utf-8"))), key=lambda e: list(e.path))
    for e in errors:
        bad += 1
        print(f"{f.name}: {'/'.join(map(str, e.path)) or '(root)'}: {e.message}")
sys.exit(1 if bad else 0)
