#!/usr/bin/env bash
# Run the unit tests of the library and the CLI. The tests need no video.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

zig build test --summary all "$@"
