#!/usr/bin/env python3
"""Turn a raw protocol capture into a committable shape fixture.

Session 1 chose a two-tier fixture scheme: `Fixtures/raw/` is gitignored and
holds real traffic — colleagues' messages, names, ids — while only a redacted
`Fixtures/shape/` may ever enter the repository. This is the redactor, written
when the scheme was first used rather than described again.

The rule, matching ChatKit's JSONShape:

  string  -> "str(<length>)"
  int     -> itself when |n| < 1000, else "int(<digits>)"
  float   -> "float"
  bool    -> "bool"
  null    -> null
  keys    -> kept, because in pblite they are field numbers

Small integers survive because they are the *point*: pblite type tags and enum
values live there, and a fixture that redacted them would describe nothing. Ids
and timestamps are the large ones, and they go.

Usage:
    scripts/redact-capture.py OUT_DIR RAW.json [RAW.json ...]

Check the output before committing. `grep -ohE '"[^"]*"' OUT_DIR/*.json | sort -u`
should show only shape tokens and field-number keys; anything else is a leak.
"""
import json
import os
import sys


def shape(value):
    if isinstance(value, str):
        return "str(%d)" % len(value)
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return value if abs(value) < 1000 else "int(%d)" % len(str(abs(value)))
    if isinstance(value, float):
        return "float"
    if value is None:
        return None
    if isinstance(value, list):
        return [shape(item) for item in value]
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items()}
    return "?"


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    out_dir, sources = argv[1], argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    for source in sources:
        with open(source) as handle:
            redacted = shape(json.load(handle))
        destination = os.path.join(out_dir, os.path.basename(source))
        with open(destination, "w") as handle:
            json.dump(redacted, handle, indent=1)
            handle.write("\n")
        print("wrote %s" % destination)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
