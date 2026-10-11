#!/usr/bin/env bash
# Run every formatter and linter. The tools come from the nix shell. CI runs this script.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

prek run --all-files --show-diff-on-failure
