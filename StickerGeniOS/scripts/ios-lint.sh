#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
EXPECTED=$(<"${PROJECT_ROOT}/.swiftlint-version")

if ! command -v swiftlint >/dev/null 2>&1; then
  print -u2 "swiftlint ${EXPECTED} not found. Install it with: brew install swiftlint"
  exit 127
fi

# Pinned on purpose. SwiftLint's rules and their options change between releases — 0.63 narrowed
# what `line_length`'s `ignores_function_declarations` exempts, and 0.65 added new rules — so an
# unpinned linter reports a different set of violations locally than it does in CI.
INSTALLED=$(swiftlint version)
if [[ "${INSTALLED}" != "${EXPECTED}" ]]; then
  print -u2 "swiftlint ${INSTALLED} is installed, but this project is pinned to ${EXPECTED}."
  print -u2 "Install the pinned version (brew upgrade swiftlint), or update .swiftlint-version"
  print -u2 "and re-run the lint after fixing whatever the new release reports."
  exit 2
fi

cd "${PROJECT_ROOT}"

# `--fix` rewrites what SwiftLint can correct on its own; without it the run only reports.
if [[ "${1:-}" == "--fix" ]]; then
  shift
  exec swiftlint --fix "$@"
fi

# --strict: the configuration in .swiftlint.yml sets every threshold at the level the project
# means to hold, so a warning is a failure like any other.
exec swiftlint lint --strict --quiet "$@"
