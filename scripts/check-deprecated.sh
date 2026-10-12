#!/usr/bin/env bash
# Fail when the Zig code uses a name that the installed standard library marks as
# deprecated. The compiler gives no warning for these names: the old name is an
# alias of the new one, with "Deprecated" in its doc comment.
#
#   scripts/check-deprecated.sh           # checks src/ and build.zig
#   scripts/check-deprecated.sh FILE...   # checks the given files
#
# Limit: the script finds a name only where the code writes the full path from
# `std`, for example `std.mem.indexOf`. It does not find a deprecated method of a
# value, or a name behind a local alias such as `const mem = std.mem;`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$script_dir")"

# `zig env` prints ZON, not JSON.
std_dir=$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')
[[ -d $std_dir ]] || {
  echo "cannot find the standard library of zig" >&2
  exit 1
}

if (($# > 0)); then
  targets=("$@")
else
  targets=(src build.zig)
fi

# One line per deprecated declaration at the top level of a file of the standard
# library: the full path of the name, for example "std.mem.indexOf".
names=$(
  cd "$std_dir"
  find . -name '*.zig' -print0 | xargs -0 awk -f "$script_dir/deprecated-names.awk" | sort -u
)

[[ -n $names ]] || {
  echo "found no deprecated name in $std_dir: the pattern of this script is out of date" >&2
  exit 1
}

# One regular expression for all the names, with a word end after each one.
pattern=$(sed -e 's/\./\\./g' -e 's/$/\\b/' <<<"$names" | paste -sd '|')

if grep --recursive --line-number --extended-regexp --include='*.zig' -- "$pattern" "${targets[@]}"; then
  echo >&2
  echo "the lines above use a deprecated name of the standard library" >&2
  echo "the doc comment of the name in $std_dir names its replacement" >&2
  exit 1
fi
