#!/usr/bin/env bash
# Lint, then run the unit tests.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$script_dir/lint.sh"
"$script_dir/test.sh"
