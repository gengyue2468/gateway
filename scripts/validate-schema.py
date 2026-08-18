#!/usr/bin/env python3
"""Validate YAML route documents against the repository JSON schema."""

from pathlib import Path
import json
import sys

import yaml
from jsonschema import Draft202012Validator


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            f"usage: {Path(argv[0]).name} SCHEMA ROUTE...",
            file=sys.stderr,
        )
        return 2

    schema_path = Path(argv[1])
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    failed = False

    for route_path_text in argv[2:]:
        route_path = Path(route_path_text)
        document = yaml.safe_load(route_path.read_text(encoding="utf-8"))
        errors = sorted(
            validator.iter_errors(document),
            key=lambda error: ([str(item) for item in error.absolute_path], error.message),
        )
        if not errors:
            continue

        failed = True
        for error in errors:
            location = ".".join(str(item) for item in error.absolute_path) or "$"
            print(f"{route_path}: {location}: {error.message}", file=sys.stderr)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
