#!/usr/bin/env bash
# Tag a release. The script reads the Conventional Commits since the last tag,
# computes the next version with git-cliff, writes that version into build.zig.zon,
# regenerates CHANGELOG.md, then commits and tags:
#
#   scripts/release.sh          # the version comes from the commits
#   scripts/release.sh 0.3.0    # the version comes from the argument
#
# The script pushes nothing. `git push --follow-tags` sends the tag.
#
# Needs git-cliff, from the nix flake.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$script_dir")"

zig_manifest="build.zig.zon"
changelog="CHANGELOG.md"
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'

cd "$repo_dir"

command -v git-cliff >/dev/null || {
  echo "git-cliff is missing: enter the nix shell" >&2
  exit 1
}

# Untracked files stay out of the release, so only the tracked ones matter here.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || {
  echo "the tracked files have changes: commit or stash them first" >&2
  exit 1
}

version="${1:-$(git cliff --bumped-version)}"
version="${version#v}"
tag="v$version"

[[ "$version" =~ $version_pattern ]] || {
  echo "'$version' is not a version number" >&2
  exit 1
}

! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
  echo "the tag $tag exists" >&2
  exit 1
}

# The only version of the repository: build.zig reads it and passes it to the library and the CLI.
sed -i "s/^\( *\.version = \)\"[^\"]*\"/\1\"$version\"/" "$zig_manifest"

git cliff --tag "$tag" --output "$changelog"
# The notes of this release alone: no header, no footer, and no version heading,
# because the name of the release carries the version already.
notes="$(git cliff --tag "$tag" --unreleased --strip all | sed "/^## \[/d")"

git add -- "$zig_manifest" "$changelog"
git commit --quiet --message "chore(release): $tag"
# The message of the tag is the notes alone, so that the release takes them as they are.
# `--cleanup=whitespace` keeps the "###" headings, which the default mode strips.
git tag --annotate --cleanup=whitespace "$tag" --message "$notes"

echo "$tag is ready. Push it with: git push --follow-tags"
