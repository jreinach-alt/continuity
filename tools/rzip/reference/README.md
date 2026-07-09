# Vendored RZIP reference (the OS's own container code)

This directory vendors the exact libretro-common sources that NextUI's
minarch and RetroArch compile for the RZIP save container — so
`continuity-rzip` is validated against the OS's REAL code output, not
a reading of the format spec. `tests/unit/tools/test_rzip_interop.sh`
compiles these files into an oracle (`ref-rzip`, whose CLI mirrors
minarch's exact `rzipstream_write_file` / `rzipstream_read_file`
calls) and requires byte-exact interop with our codec in both
directions on every CI run.

## Provenance

Fetched 2026-07-07 from `libretro/libretro-common` @ master via
cdn.jsdelivr.net, **verbatim** (MIT license headers intact — the
license applies per-file and permits this):

- `rzip_stream.c` — the format-defining code
- `trans_stream.c`, `trans_stream_zlib.c`, `trans_stream_pipe.c`
- `include/streams/rzip_stream.h`, `include/streams/trans_stream.h`

Do not edit these files. To refresh, re-fetch from upstream and rerun
the interop test.

## Shims (`shim/`) — ours, plumbing only

`rzip_stream.c` reads/writes through libretro's file_stream VFS, which
drags in a large platform tree irrelevant to the byte format. The shim
provides that surface over plain stdio (`file_stream_stdio.c`) plus
four trivial headers (`boolean.h`, `retro_common_api.h`,
`retro_miscellaneous.h`, `file/file_path.h`). Nothing in the shim
touches container bytes — every header, chunk frame, and zlib stream
is produced by the vendored upstream code.

## Build gotcha

`trans_stream.c` gates its zlib backend behind `#if HAVE_ZLIB`;
compile with `-DHAVE_ZLIB=1` (real builds define it) or the reference
"succeeds" at building and then fails every compressed operation at
runtime with a NULL backend.

## Validated against real device files (2026-07-07)

The interop matrix was additionally run against the live saves repo's
actual files (the first Brick's raw 8 KB SRAM and both 823 KB snes9x
`#!s9xsnp` states): OS-code encode → our decode and our encode →
OS-code decode were byte-identical for all of them, and the reference
reader's raw-passthrough behavior on the snes9x states matches ours
(`#!s9xsnp` is snes9x's native snapshot magic, not a container — easy
to misread from a hex dump).
