# floralogin — implementation notes

Design rationale mined from `floralogin.c`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history.

## Why it exists

util-linux's own `login` unconditionally requires PAM to build at all —
FloraOS ships no PAM. Verifies `/etc/shadow` via `crypt(3)` (libxcrypt,
since glibc itself dropped `crypt()`), execs the user's shell as a login
shell on success. No PAM, no session management beyond what a plain
crypt-based login always did. Meant to run under a real `agetty` that's
already opened the tty as session leader — **that's** what actually fixes
job control (agetty properly attaches the controlling tty; bash spawned
directly never did); this program only replaces util-linux's own `login`,
not `agetty` itself.

## EOF/hangup must end the program, not loop forever

`read_line()` returning `-1` on EOF is load-bearing: a hangup at the
prompt (stdin closed) has to end the program instead of spinning forever
re-printing the login prompt on an endless stream of "empty lines" —
reproduced directly (piping a closed stdin into an earlier version of
this program looped printing the prompt until killed).

## Root's empty password

An empty shadow hash field is traditional Unix for "no password required"
— intentional for this live, RAM-resident image (see the top-level
README); a persistent install sets a real hash via `florauser passwd` once
one exists.

## Brute-force throttling

A failed login sleeps 2 seconds before re-prompting, matching traditional
`login(1)`.

## Clearing the password buffer: `explicit_bzero`, not `memset`

A plain `memset` immediately before a stack buffer is reused/overwritten
(as `password` is, on the next loop iteration) is a case an optimizing
compiler is explicitly permitted to eliminate entirely as dead code
(CWE-14) — this project builds with `-O2`. `explicit_bzero` (glibc, added
2.25) is specifically designed to never be optimized away regardless of
what happens to the buffer afterward. `florauser.c`'s own password
handling has the identical fix, for the identical reason.

## `XDG_RUNTIME_DIR`

No session manager exists (no logind, no elogind) to set this up the usual
way, but any Wayland compositor (mango, sway, ...) hard-requires it at
startup. `/run` is already RAM-backed as part of the whole
initramfs-resident image, so a plain `mkdir` here is enough — no separate
tmpfs mount needed. Root-owned `0700` per the XDG base-dir spec; failure
here is non-fatal (falls through to a login shell either way), same
"warn and continue" spirit as `floraseat`'s own socket-group setup.
