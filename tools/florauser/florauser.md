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

## `florauser rename <old> <new>`

Renames a user across every file that names it, not just `/etc/passwd`:

- **`/etc/passwd`**: the name field itself, and the home directory field if
  (and only if) it follows `cmd_add`'s own `/home/<name>` convention — a
  custom home path is left exactly as-is rather than guessed at, with a
  note printed saying so.
- **`/etc/shadow`**: just the name field — hash and all aging fields
  (min/max/warn/inactive/expire) are copied verbatim, untouched.
- **`/etc/group`**: the user-private group is renamed too, but only if one
  actually matches `cmd_add`'s convention (same name *and* same gid as the
  user) — a group that merely happens to share the old username by
  coincidence is left alone. Every group's member list also gets the
  `<old>` token replaced with `<new>`, since `addtogroup` stores the
  literal username there.
- **The home directory itself** is renamed on disk (`rename(2)`) before any
  file is rewritten — so if that fails partway through (permission,
  cross-device, or simply no home directory ever existed), the *old*,
  still-working path is what ends up recorded, not a dangling one.

Refuses to rename `root` outright: too much of the rest of this project
(floralogin's empty-password convention, florainstall's account setup)
hardcodes `"root"` as a literal string for renaming it to silently break
elsewhere, not just here. Not a single atomic transaction across the three
files — same disclosed limitation as everything else in this tool (no
locking, no rollback) — but ordered passwd → shadow → group specifically so
an interruption partway through leaves the user's own login identity
(`passwd`) already consistent, rather than the reverse.

**A real bug an actual test run caught, not just reasoned through**: the
first version's group-member-list rebuild replaced the `<old>` token with
`<new>` unconditionally, with no check for whether `<new>` was *already* a
member of that same group (a real, unrelated user, or simply re-running the
same rename) — producing a literal `"bob,bob"` member list instead of
`"bob"`. Fixed by tracking which token has already been written and
skipping any further occurrence of it, so the result always has each name
at most once regardless of what the group already contained.

## Verification

Built with `-Wall -Wextra` (clean), then exercised end-to-end against a
scratch `passwd`/`group`/`shadow` (uid/gid allocation including the
"a group already took this gid" case, user-private-group creation,
supplementary group join, idempotent `addtogroup`, `groupadd`, password
set + mismatch handling producing a real yescrypt `$y$` hash, and expected
rejections: duplicate user, invalid name, missing group). `rename` was
verified two ways: a standalone scratch-file harness (path macros
temporarily redirected via `sed`, run under `fakeroot` to satisfy the
`getuid() == 0` check without touching this host's real files) exercising
the standard-home-layout case, the custom-home-layout case, the
duplicate-group-member case above, and the reject cases (root, existing
name, nonexistent user, invalid name); then a real root-privileged run
against a live FloraOS rootfs in QEMU (`fau user-add alice seat`, `fau
user-passwd alice`, `fau user-rename alice bob`, confirmed the renamed
`passwd`/`shadow`/`group` entries directly, and logged in as `bob` with
`alice`'s original password, confirming `id` still shows the `seat` group
membership). That real-rootfs gap the rest of this file's history section
used to flag is now closed the same way `scripts/test-install.sh` closed it
for florainstall/`fau backup`.
