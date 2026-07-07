# florauser — implementation notes

Design rationale mined from `florauser.c`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history.

## Why it exists

Same reasoning as `floralogin`/`fauelf`/`floraseat`: shadow-utils expects a
PAM-shaped world FloraOS doesn't have. Closes a real gap: `floraseat`/
`eudev`/`floralogin`'s own `XDG_RUNTIME_DIR` setup all work for *any* user
already in `/etc/passwd`, but there was no way to create a second, non-root
user at all — root was the only login that could ever exist. This is what
`usermod -aG seat <user>` (floraseat's own documented migration path)
actually needs something to run first.

## No NSS — direct file parsing, on purpose

Every lookup goes through this file's own `PASSWD_PATH`/`GROUP_PATH`/
`SHADOW_PATH` constants and a hand-rolled colon-field parser —
deliberately **not** `getpwnam()`/`getgrnam()`/`getspnam()`, which resolve
through glibc's NSS and would depend on `/etc/nsswitch.conf` being present
and sane. FloraOS ships no `nsswitch.conf` at all. Confirmed necessary in
practice, not just theoretical: an early version of this file called
`getpwnam()` from `florauser passwd`, which worked fine against the real
rootfs but made the tool untestable in isolation without faking a matching
NSS/user database — switching to the same file-parsing path as every other
command fixed both problems at once.

## Two different "no password" conventions, deliberately

- `floralogin`'s convention: an **empty** shadow hash field means "no
  password required" (root-only, intentional for the live RAM-resident
  image).
- `florauser add`'s convention: a **locked** (`!`) password field — a
  freshly created account can't log in until `florauser passwd` gives it a
  real hash. An empty field here would silently mean "no password
  required", which is not a safe default for a newly created non-root
  account.

## `florauser passwd`'s "same as root's" shortcut

Leaving the first prompt blank for any user other than root copies root's
own current `/etc/shadow` hash verbatim instead of hashing an empty
password — lets `florainstall`'s own "additional user" step offer "same as
root" to someone who doesn't want to think of and type a second password.
Requires root to already have a real (non-empty, non-locked) password set;
fails otherwise, same as any other missing-shadow-entry case.

## Password hashing

`crypt_gensalt(NULL, 0, NULL, 0)` — `NULL` rbytes means it draws its own
salt from `/dev/urandom`; `NULL` prefix + count `0` means libxcrypt's own
strongest default algorithm, not a hand-picked one. Matches how real
`passwd(1)` does it.

## Deliberately not done

No file locking against a second concurrent `florauser`/`floralogin`
invocation (root is the only admin today, and this is an interactively-run
admin tool, not a daemon). No password-complexity policy, no
`/etc/login.defs`, no NIS/LDAP — none of that exists elsewhere in FloraOS
either. Known limitations, not bugs.

## Verification

Built with `-Wall -Wextra` (clean), then exercised end-to-end against a
scratch `passwd`/`group`/`shadow` (uid/gid allocation including the
"a group already took this gid" case, user-private-group creation,
supplementary group join, idempotent `addtogroup`, `groupadd`, password
set + mismatch handling producing a real yescrypt `$y$` hash, and expected
rejections: duplicate user, invalid name, missing group). What was **not**
verified at the time this was written: an actual root-privileged run
against a real FloraOS rootfs's live files, or a real login using a
florauser-created account — that gap has since been closed for the
florainstall/`fau backup` path by `scripts/test-install.sh`'s real QEMU
boot test (see docs/ARCHITECTURE.md).
