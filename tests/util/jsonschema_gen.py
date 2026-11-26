"""Extract JSON Schema 2020-12 test cases for the keywords util/jsonschema.lua supports
from the official JSON-Schema-Test-Suite (dev-only):

    git clone --depth 1 https://github.com/json-schema-org/JSON-Schema-Test-Suite /tmp/jsts
    python3 -I tests/util/jsonschema_gen.py /tmp/jsts  ->  tests/fixtures/jsonschema_suite.json

Kept: test cases compatible with 2020-12 whose schemas use only supported keywords and
in-document $refs (no $id, $anchor, $dynamicRef, unevaluated*, remote refs).
"""
import json
import pathlib
import sys

FILES = [
    "type", "enum", "const", "multipleOf", "minimum", "maximum", "exclusiveMinimum",
    "exclusiveMaximum", "minLength", "maxLength", "pattern", "items", "prefixItems",
    "contains", "minContains", "maxContains", "minItems", "maxItems", "uniqueItems",
    "properties", "patternProperties", "additionalProperties", "required",
    "dependentRequired", "dependentSchemas", "propertyNames", "minProperties",
    "maxProperties", "allOf", "anyOf", "oneOf", "not", "if-then-else", "boolean_schema",
    "default", "ref", "defs",
]
UNSUPPORTED = {"$id", "$anchor", "$dynamicRef", "$dynamicAnchor", "$recursiveRef",
               "$recursiveAnchor", "unevaluatedProperties", "unevaluatedItems",
               "$vocabulary", "$schema", "contentMediaType", "contentEncoding", "contentSchema",
               "dependencies", "additionalItems", "definitions"}
ORDER = [3, 4, 6, 7, 2019, 2020]


def compatible(spec, version=2020):
    if not spec:
        return True
    ok = False
    lo = None
    for c in spec.split(","):
        c = c.strip()
        if c.startswith("<="):
            hi = int(c[2:])
            if (lo is None or version >= lo) and version <= hi:
                ok = True
            lo = None
        elif c.startswith("="):
            if version == int(c[1:]):
                ok = True
            lo = None
        else:
            if lo is not None and version >= lo:
                ok = True
            lo = int(c)
    if lo is not None and version >= lo:
        ok = True
    return ok


def uses_unsupported(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in UNSUPPORTED:
                return True
            if k == "$ref" and isinstance(v, str) and not v.startswith("#"):
                return True
            if k == "format":
                return True
            if uses_unsupported(v):
                return True
    elif isinstance(node, list):
        return any(uses_unsupported(x) for x in node)
    return False


def main():
    root = pathlib.Path(sys.argv[1]) / "validation" / "tests"
    out = []
    for name in FILES:
        path = root / f"{name}.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for case in data["tests"]:
            if not compatible(case.get("compatibility")) or uses_unsupported(case["schema"]):
                continue
            out.append({"file": name, "description": case["description"], "schema": case["schema"],
                        "tests": [{"description": t["description"], "data": t["data"], "valid": t["valid"]}
                                  for t in case["tests"]]})
    dest = pathlib.Path(__file__).parent.parent / "fixtures" / "jsonschema_suite.json"
    dest.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {len(out)} test cases, {sum(len(c['tests']) for c in out)} tests to {dest}")


main()
