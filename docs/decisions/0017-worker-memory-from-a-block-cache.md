# 0017: A worker keeps its large blocks of memory

Date: 2026-10-12. Status: accepted.

## Context

After decision 0015, the run on the benchmark video had 20 s of system time in
185 s of CPU time. `perf stat -e page-faults` counted 5.8 million page faults.

The cause was the memory of the render jobs:

- Each job took its frames from the general allocator, and its working memory
  from a new arena. At the end of the job, all of it went back.
- `std.heap.smp_allocator` takes each block of 64 KiB or more from the system,
  and gives it back to the system at the free. The system clears each page of a
  new block before the first write. That is one page fault per page.
- An arena does not use a block again in one job. A job held each block that it
  took until its end.

## Decision

### `memory.BlockCache`

The library has an allocator on top of a child allocator, `memory.BlockCache`.

- A block of 64 KiB or more that the caller frees stays in the cache. The next
  request of the same size and alignment gets it. The pages of a document have
  one size, so the same sizes come again and again.
- A smaller request goes to the child allocator with no change.
- The cache holds at most 256 blocks. When it is full, the block that waits for
  the longest time goes back to the child allocator.
- The cache has no lock. One thread uses one cache.

The library uses no arena behaviour: it frees each block that it takes from
`scratch`. The tests check that with the leak check of `std.testing.allocator`.
So `scratch` can be a cache, an arena, or a general allocator.

### The CLI has one cache per worker

`parallel.forEach` gives each job the index of its worker. The signature step and
the render step take from the cache of the worker:

- the full-size frames;
- the working memory of `renderSignature`, `renderSpread`, and `encodePage`;
- the page images before the JPEG step.

The encoded page and the signature stay after the job, so they come from the
general allocator.

### The JPEG encoders take `scratch`

`jpeg.encodeGray` and `jpeg.encodeRgb` have a `scratch` parameter for their
planes and coefficients. Only the bytes of the result come from `allocator`.
Before, the planes of the encoder were 41 % of the page faults that stayed.

### Why not an arena per worker with `reset(.retain_capacity)`

- An arena does not use memory again in one job. Each worker then holds the sum
  of all requests of its largest job. With the cache, a worker holds only the
  blocks that are in use at the same time: 590 MB.
- After the reset, the arena of Zig 0.17 has one new block of the full size. The
  pages of that block are new again. The same occurs after each job that needs
  more memory than the jobs before it. A worker has about six jobs on the
  benchmark, so many of them get new pages.

## Measurements on the benchmark video

Three runs of each binary in turn, with a warm frame cache, on 2026-10-12. The
machine did no other work.

| | Before | With the cache |
|---|---|---|
| Page faults | 5.82 million | 1.05 million |
| System time | 20.4 s | 8.4 s |
| User time | 165 s | 158 s |
| Run time | 31.2 s | 29.0 s |
| Peak memory of the process | 5.4 GB | 4.7 GB |
| Bytes of the PDF | 13 151 121 | 13 151 121, the same bytes |

With `--verbose`, the program prints the numbers of the caches. On the benchmark:
1 217 large blocks from the system (4.7 GB), and 11 920 requests that got a block
of a cache.

The run time of this table is lower than the 38 s to 41 s of decision 0015. That
is not a gain of the program: on 2026-10-11 the machine did other work during the
runs.

## Consequences

- A worker holds about 590 MB until the render step ends. A caller with one
  thread, for example a phone app, uses one cache for all jobs.
- A block from the cache holds old data. Code that reads memory before it writes
  it gets other values in each run. Two checks guard this: the PDF of the
  benchmark has the same bytes as before, and a debug build fills each freed
  block with a pattern before the tests read it again.
- The system time that stays has two causes: the first write to the 4.7 GB, and
  the copy of 10 GB of frames from the cache files.
- The analysis pass keeps its own memory rule: one block per job that it uses
  again for each frame.
