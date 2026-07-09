# fauelf — implementation notes

Design rationale mined from `fauelf.c`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history and [../fau/fau.md](../fau/fau.md) for how `fau` calls this.

## Why it exists

Some Arch/Artix packages (found via `neovim`'s `lua51-lpeg` dependency)
bake a literal absolute path into a `DT_NEEDED` entry — e.g.
`/usr/lib/lua/5.1/lpeg.so` — instead of a bare soname like `liblpeg.so`.
glibc's dynamic linker only consults `RPATH`/`RUNPATH`/`LD_LIBRARY_PATH`
for a *bare* soname; an absolute `DT_NEEDED` is opened literally, bypassing
all of that. That's invisible for a normal system install (`FAU_ROOT`
really is `/`, so the absolute path happens to resolve) but breaks `fau`'s
isolated app installs outright: the dependency is correctly bundled inside
`~/apps/<name>/usr/lib/...`, and the app wrapper's `LD_LIBRARY_PATH`
already covers that directory, but the dynamic linker never gets a chance
to use it. Confirmed by reproducing "cannot open shared object file" for
exactly this file inside a real chroot of the built rootfs, not just by
reading the code.

Written from scratch (no libelf, no patchelf) the same way
`floralogin`/`fau` themselves are — a small, auditable, purpose-built tool
rather than a vendored dependency.

## Why rewriting in place is always safe

The basename is strictly shorter (or equal) in length than the original
absolute path, so it always fits inside the string's already-allocated
slot in `.dynstr` with NUL padding — no relocation, no resizing, nothing
else in the file moves.

## Usage contract

`fauelf <file> [file ...]` is meant to be run over *every* file in an
extracted package's payload, most of which won't be ELF at all:
- Not a regular ELF64 file, or has no `PT_DYNAMIC` segment: silently does
  nothing for that file, moves on to the next one.
- Rewrites every absolute `DT_NEEDED` entry found, logs each rewrite to
  stdout, moves on to the next file.
- A file that *does* look like ELF64 with a dynamic section but is
  truncated/corrupt in a way that breaks the format's own internal
  consistency: prints an error to stderr and exits 1 immediately (not just
  skipping that one file) — matches `fau`'s own "any real corruption aborts
  the whole build" stance.

`vaddr_to_offset` translates `DT_STRTAB`'s virtual address back to a file
offset via the `PT_LOAD` segment that contains it — the standard way a
real dynamic linker resolves this.

## Multiple files per invocation

`fau`'s own callers (`lib/alpm.sh`, `lib/build.sh`) run this over every
file in an extracted package via `find ... -print0 | xargs -0 fauelf`, not
one invocation per file — measured directly against a real 14,812-file
rootfs tree: 7.2s for one-fork-per-file vs 0.055s batched (~130x), byte-
identical output verified both ways. The one thing this requires that a
single-shot process didn't: every early return in `process_file` must
explicitly `close()`/`free()` whatever it already opened/allocated, since
process exit no longer reclaims that between files.
