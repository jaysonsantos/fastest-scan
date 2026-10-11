#!/usr/bin/env bash
# Build the optimized CLI and the libraries into zig-out/.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

zig build --release=fast "$@"
