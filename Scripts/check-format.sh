#!/usr/bin/env bash
# Lint the Swift sources against the Apple style, as configured in
# `.swift-format`.  Pass `--fix` to rewrite the files in place instead of
# reporting on them.
#
# The formatter is the one inside the active Xcode toolchain, reached via
# `xcrun`, so it needs no separate install and cannot drift from the
# compiler the project is built with.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sources=(MonoCl MonoClTests Packages)

if [[ "${1:-}" == "--fix" ]]; then
  xcrun swift-format format --recursive --in-place "${sources[@]}"
  echo "Formatted ${sources[*]}."
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "usage: $(basename "$0") [--fix]" >&2
  exit 2
fi

# --strict promotes the findings to a non-zero exit, which is what makes
# this a gate rather than a report.
xcrun swift-format lint --recursive --strict "${sources[@]}"
echo "Sources match the configured Apple style."
