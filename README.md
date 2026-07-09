# FloraOS

A Linux distribution built from scratch, source up. No systemd, no Arch or
Artix binaries anywhere in the base image: every package is compiled from
pinned upstream source (`config/versions.conf`). OpenRC and sysvinit handle
init. GNU userland underneath. And `fau`, FloraOS's own system manager,
handles everything else: packages, backups, services, users, written from
the ground up instead of forked from something that already exists.

## The idea

Most distros scatter an installed app across `/usr`, `/etc`, `/var/log`, and
hope you never actually need to remove one cleanly. FloraOS doesn't.
`fau install firefox` puts everything under `~/apps/firefox/`: binary,
config, cache, logs, one self-contained folder. `fau remove firefox` deletes
that folder. Nothing else on the system is touched. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#app-isolation-per-app-directories-under-apps)
for how that actually works, and where its limits are.

## Where it stands

`./floraiso test` boots a real kernel, checks a real credential over a
serial console, and reaches a shell. Not a "should work," a driven,
end to end QEMU run. From there:

- **fau resolves real Arch/Artix packages on its own.** No `pacman`
  involved, not even to fetch one. It reads the sync-db and mirrorlist
  formats directly, resolves virtual packages and version constraints, and
  works the same whether it's building the ISO or running inside an
  already-booted system that ships no `pacman` at all.
- **A GUI stack is one `fau install` away.** eudev for device nodes, a
  from-scratch seat daemon (`floraseat`) speaking the real seatd protocol,
  a generic KMS driver built into the kernel. Nothing graphical ships by
  default, but everything a Wayland compositor needs to talk to hardware
  already does.
- **Real login, no PAM.** util-linux's own `login` won't build without it.
  `floralogin` is a small, from-scratch replacement that checks
  `/etc/shadow` directly.
- **Full-root btrfs snapshots.** `fau backup` before you break something,
  `fau backup-restore` to pick a GRUB entry and go back.
- **A disk installer that's actually been booted, not just compiled**:
  BIOS and UEFI, tested end to end in QEMU/KVM.
- **192MB**, hybrid BIOS and UEFI, boots and runs entirely from RAM.

The full package list and a one-line reason for every one of them lives in
[docs/MANIFEST.md](docs/MANIFEST.md). The design history and every real bug
a boot test caught along the way: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
What's deliberately not done yet: [docs/TODO.md](docs/TODO.md).

## Try it

```
./floraiso build   # builds the rootfs (if needed) and the ISO
./floraiso test    # boots it in QEMU, checks it actually reaches a shell
```

Log in as `root` with an empty password (just press Enter). From there,
`florainstall` puts FloraOS on a real disk. It's a one-shot operation with
no undo, so it asks you to type the disk's name back before touching
anything.

Nothing here needs configuration to build. To change the hostname, add
packages, or rename the ISO, edit `config/floraos.conf`, the only config
file this project has.

## Layout

```
config/floraos.conf      the one config file: hostname, extra packages, kernel version, ISO name
config/versions.conf     pinned source URL + sha256 for every base package
docs/                    architecture, package manifest, filesystem layout, TODO
assets/                  fastfetch logo + config
tools/fau/               fau: the system manager (dispatcher + subtools + lib/)
tools/floralogin/        PAM-free login
tools/floraseat/         seatd-protocol-compatible seat daemon
tools/florauser/         useradd/passwd/groupadd/rename
tools/fauelf/            absolute-DT_NEEDED fixup for isolated apps
tools/florainstall/      TUI disk installer
tools/floragrub-cfg/     grub.cfg generator, shared by florainstall and fau backup
scripts/                 rootfs and ISO build pipeline, one recipe per base package
work/                    build output, gitignored, nothing here is committed
```

Every tool has its own `<name>.md` next to it: design rationale and the real
bugs a boot test found, not a restatement of what the code already says.

## fau

Packages and backups are what exist today; fau is meant to keep growing
into managing the rest of the running system, not stay scoped to packages
alone.

```
fau install <pkg>       # -> isolated under ~/apps/<pkg>/
fau remove <pkg>
fau list
fau backup <name>       # full-root snapshot, restorable from the GRUB menu
fau backup-restore <name>
fau service-list / service-enable / service-start / ...
fau seat-status / seat-switch <vt>
fau user-add / user-passwd / user-rename / ...
```

`fau help [topic]` for the full command reference.
[tools/fau/fau.md](tools/fau/fau.md) for how it's built and every real bug
found getting it there.

## License

MIT, see [LICENSE](LICENSE).
