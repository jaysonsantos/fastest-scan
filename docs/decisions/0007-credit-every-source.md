# 0007: Credit every source

Date: 2026-10-09. Status: accepted. The owner of the repository set this rule.

## Context

Research agents bring in algorithms from papers, patents, blog posts, and open
source programs. Some of those programs have a license (GPL) that does not fit the
MIT license of this repository.

## Decision

- The comment of each algorithm names its source: authors, title, place, year.
- `docs/references.md` lists all sources in one place. A commit that adds an
  algorithm also adds its source there.
- From a program with a license that does not fit MIT, the project takes the idea
  only. The code is written new, and the entry in `docs/references.md` says so.
- A research note keeps the mark that says if a claim was read in the source.

## Consequences

- A reviewer can check each algorithm against its paper.
- The JPEG encoder carries the acknowledgement that the license of the Independent
  JPEG Group asks for.
