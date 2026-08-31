#!/usr/bin/env python3
"""Compare a captured fixture's shape against a live response.

Directional by design: every named key must exist in BOTH documents and
hold the same JSON type in each.  Keys present only in the live response
are ignored, because the live response carries many keys MonoCl does not
consume and new ones appearing is routine rather than drift.
"""
import argparse
import json
import sys


def kind(value):
    """The JSON type name, with bool checked before int — in Python
    `isinstance(True, int)` is true, which would report a bool as a
    number."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if value is None:
        return "null"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return type(value).__name__


def descend(doc, path):
    for step in path:
        if not isinstance(doc, dict) or step not in doc:
            return None
        doc = doc[step]
    return doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--live", required=True)
    parser.add_argument("--path", nargs="*", default=[])
    parser.add_argument("--keys", nargs="+", required=True)
    parser.add_argument(
        "--optional",
        action="store_true",
        help="a path missing from the live response is a NOTE, not drift",
    )
    parser.add_argument(
        "--percentage",
        default=None,
        help="key whose value must look like a 0-100 percentage",
    )
    args = parser.parse_args()

    with open(args.fixture) as handle:
        fixture = descend(json.load(handle), args.path)
    with open(args.live) as handle:
        live = descend(json.load(handle), args.path)

    where = ".".join(args.path) or "(root)"

    if fixture is None:
        print(f"SKIP: the fixture has no {where}", file=sys.stderr)
        return 0

    if live is None:
        if args.optional:
            print(
                f"NOTE: the live response has no {where}; the documented "
                "contract allows it to be absent",
                file=sys.stderr,
            )
            return 0
        print(f"DRIFT: the live response has no {where}", file=sys.stderr)
        return 1

    failures = 0
    for key in args.keys:
        if key not in fixture:
            print(f"SKIP: the fixture's {where} has no {key}", file=sys.stderr)
            continue
        if key not in live:
            print(
                f"DRIFT: the live {where} has no {key}, which the fixture records",
                file=sys.stderr,
            )
            failures += 1
            continue
        want, got = kind(fixture[key]), kind(live[key])
        if want != got:
            print(
                f"DRIFT: {where}.{key} is {got} live but {want} in the fixture",
                file=sys.stderr,
            )
            failures += 1

    if args.percentage and args.percentage in live:
        value = live[args.percentage]
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            print(
                f"DRIFT: {where}.{args.percentage} is not a number",
                file=sys.stderr,
            )
            failures += 1
        elif value < 0 or value > 100:
            print(
                f"DRIFT: {where}.{args.percentage} is {value}, outside 0-100",
                file=sys.stderr,
            )
            failures += 1
        elif 0 < value <= 1:
            # Deliberately NOT drift.  0.5 is an entirely normal
            # percentage shortly after a window resets, and it is also
            # what a reverted fraction would look like.  The two are
            # indistinguishable from a single sample, so reporting drift
            # here would be a confident claim the data cannot support.
            print(
                f"NOTE: {where}.{args.percentage} is {value}; a low "
                "percentage and a fraction are indistinguishable from one "
                "sample, so check it against claude.ai/settings/usage",
                file=sys.stderr,
            )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
