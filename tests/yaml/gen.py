"""Generate expected JSON for tests/yaml/cases/*.yaml using PyYAML (dev-only)."""
import json
import pathlib
import yaml

root = pathlib.Path(__file__).parent / "cases"
for src in sorted(root.glob("*.yaml")):
    data = yaml.safe_load(src.read_text(encoding="utf-8"))
    out = src.with_suffix(".json")
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1, default=str) + "\n", encoding="utf-8")
    print("wrote", out.name)
