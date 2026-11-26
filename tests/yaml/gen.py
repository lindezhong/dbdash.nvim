"""Generate expected JSON for tests/yaml/cases/*.yaml using PyYAML (dev-only), after
copying the example configs into tests/yaml/cases/ (they are parser cases too)."""
import json
import pathlib
import yaml

root = pathlib.Path(__file__).parent / "cases"

# The example configs are parser cases too: copy them in first (example/<topic>/<name>.yaml
# becomes cases/example_<topic>_<name>.yaml), replacing older copies.
examples = pathlib.Path(__file__).parent.parent.parent / "example"
for old in root.glob("example_*"):
    old.unlink()
for src in sorted(examples.glob("*/*.yaml")) + [examples / "dbdash.schema.yaml"]:
    rel = src.relative_to(examples).with_suffix("").as_posix().replace("/", "_").replace(".", "_")
    (root / f"example_{rel}.yaml").write_bytes(src.read_bytes())
for src in sorted(root.glob("*.yaml")):
    data = yaml.safe_load(src.read_text(encoding="utf-8"))
    out = src.with_suffix(".json")
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1, default=str) + "\n", encoding="utf-8")
    print("wrote", out.name)
