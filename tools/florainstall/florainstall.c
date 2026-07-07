/* florainstall -- FloraOS's own TUI disk installer, written from scratch the
 * same way fau/floralogin/florauser/floraseat/fauelf are: small, auditable,
 * purpose-built, reusing FloraOS's own existing tools instead of vendoring
 * a general-purpose installer framework.
 *
 * What "installing" FloraOS actually means here: the live ISO boots the
 * entire rootfs unpacked as an initramfs (see scripts/build-iso.sh) -- the
 * running system's "/" already *is* the fully-built OS, RAM-resident. There
 * is no separate "installer payload" to unpack. So florainstall's real job
 * is: partition a real disk, format it, copy the live "/" onto it (rsync,
 * already a base package -- see docs/MANIFEST.md), then make it bootable
 * and give it a real login.
 *
 * Filesystem: btrfs, not ext4 -- FloraOS ships no btrfs-progs in the base
 * image either way (same as it ships no GRUB, see below), so this is
 * fetched at install time via fau's own alpm fallback too, except onto the
 * *live* system itself rather than the target: `fau bootstrap btrfs-progs`
 * with FAU_ROOT left at its default ("/") merges mkfs.btrfs straight into
 * the running image, because it has to actually run before the target disk
 * even has anything mounted on it (unlike grub-install below, which
 * genuinely needs to run inside a chroot into the target). fau's alpm
 * fallback resolves btrfs-progs' own real dependency closure the same way
 * it does for any other package -- this project isn't hand-guessing its
 * linked libraries.
 *
 * Partition scheme: classic MBR (dos label), one bootable Linux (0x83)
 * partition spanning the disk. Deliberately NOT GPT+"BIOS boot partition":
 * that scheme needs a specific partition-type GUID which isn't something
 * this project can verify against a primary source from inside this build
 * (unlike, say, linux-lts.sh's Kconfig symbols, which were checked directly
 * against git.kernel.org) -- MBR sidesteps the question entirely, since
 * grub-install --target=i386-pc's classic embedding gap between the MBR and
 * the first partition (sfdisk's default 1MiB alignment already leaves this)
 * has been the standard BIOS-GRUB2 install method for well over a decade,
 * no dedicated partition required. UEFI (an ESP, FAT32) is deliberately not
 * supported yet -- FloraOS ships no dosfstools (see docs/MANIFEST.md), and
 * the live ISO's own tested boot path is BIOS via grub-mkrescue's hybrid
 * image, not UEFI -- same "TODO over silence" rule as ARCHITECTURE.md's
 * other gaps, not a silent omission.
 *
 * Bootloader: GRUB itself is not built from source (ARCHITECTURE.md already
 * ruled that out for the ISO -- 16-bit real-mode boot code, i386-pc/
 * x86_64-efi module builds are a lot of surface for a from-scratch distro
 * to compile correctly). Fetched instead via fau's own existing alpm
 * (Arch/Artix repo) fallback, straight into the *target* disk's tree
 * (`FAU_ROOT=<target-mount> fau bootstrap grub`) -- same mechanism that
 * already fetches wlroots/sway/mango for `fau install <wm>`, just pointed
 * at a different root. grub-install itself then has to run *inside* a
 * chroot into that target (not just given --boot-directory from the live
 * environment): its shared library dependencies live under the target's
 * own /usr/lib, not the live system's, and the dynamic linker only
 * consults the filesystem root it's actually running under.
 *
 * User accounts: this tool never touches a plaintext password itself. It
 * shells out to the real `florauser` (tools/florauser) inside the same
 * chroot, with the terminal inherited -- florauser's own interactive,
 * termios-masked double-prompt (the same code path floralogin's
 * read_password uses) runs directly against the target's /etc/shadow.
 * "Use the user manager from the system" applies literally: florainstall
 * does not reimplement any part of account creation.
 *
 * Kernel image: build-iso.sh's own initramfs-packing step deliberately
 * excludes ./boot from the live image (GRUB reads boot/vmlinuz-floraos
 * directly off the ISO's own boot/ directory; embedding it a second time
 * inside the initramfs it boots from would be redundant) -- confirmed by
 * reading that script directly, not assumed. That means the *running* live
 * system has no /boot/vmlinuz-floraos to copy from at all. Fixed with one
 * extra staging line in build-rootfs.sh that copies the kernel to
 * /usr/lib/floraos/vmlinuz-floraos (a path that isn't under ./boot, so it
 * does survive into the live initramfs) purely for this tool's own use.
 *
 * Not independently boot-tested end-to-end in this sandbox (no spare disk/
 * real hardware or a QEMU disk-boot harness available here) -- treat this
 * the same as any other unverified change in this codebase: check a real
 * `florainstall` run followed by an actual reboot off the target disk
 * before relying on it. Assumptions specifically worth re-checking then:
 * that this kernel's defconfig builds CONFIG_BTRFS_FS in (=y, not =m --
 * there is no initramfs on the installed system to load a module from
 * before root is mounted; scripts/recipes/linux-lts.sh now enables this
 * explicitly, same as the earlier DRM_SIMPLEDRM work, but a from-scratch
 * kernel build wasn't practical to run in this sandbox either), and that
 * Arch's `grub`/`btrfs-progs` package names and repo layout are still what
 * fau's alpm fallback expects.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <menu.h>
#include <ncurses.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* BLKRRPART ("re-read partition table"): the ioctl number itself
 * (type 0x12, nr 95 -- both stable since the earliest Linux block-ioctl
 * numbering, unchanged for decades) is hand-computed here rather than
 * pulled in via <linux/fs.h>, which on some libc/kernel-header pairings
 * redefines macros <sys/mount.h> (needed just above for mount(2)/MS_BIND)
 * already provides. _IO(0x12, 95) with _IOC_NONE (0) reduces to
 * (0x12 << 8) | 95.
 */
#ifndef BLKRRPART
#define BLKRRPART 0x125f
#endif

#define TARGET_MNT "/mnt/florainstall"
#define LIVE_KERNEL_PATH "/usr/lib/floraos/vmlinuz-floraos"

struct disk_info {
	char name[256]; /* e.g. "sda", "nvme0n1" -- as it appears under /sys/block */
	char path[280]; /* "/dev/sda" */
	unsigned long long bytes;
};

struct install_settings {
	struct disk_info disk; /* disk.name[0] == 0 means "not chosen yet" */
	char hostname[64];
	int create_user;      /* 0/1 */
	char username[32];
	char groups[128];     /* comma-separated, e.g. "seat" -- may be empty */
};

/* --- cleanup bookkeeping: what's currently mounted, so both the normal
 * end-of-install path and any die() partway through can unwind safely --- */
static int g_target_mounted = 0;
static int g_dev_bound = 0;
static int g_sys_bound = 0;
static int g_proc_bound = 0;

static void log_msg(const char *fmt, ...) {
	va_list ap;
	fprintf(stdout, "florainstall: ");
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	fprintf(stdout, "\n");
	fflush(stdout);
}

static void unmount_best_effort(const char *path) {
	if (umount(path) == 0) return;
	umount2(path, MNT_DETACH);
}

/* Unwinds every bind-mount/mount this tool may have made, innermost first.
 * Safe to call more than once and safe to call when nothing is mounted yet
 * (each step is guarded by its own flag). */
static void cleanup_mounts(void) {
	if (g_dev_bound) { unmount_best_effort(TARGET_MNT "/dev"); g_dev_bound = 0; }
	if (g_sys_bound) { unmount_best_effort(TARGET_MNT "/sys"); g_sys_bound = 0; }
	if (g_proc_bound) { unmount_best_effort(TARGET_MNT "/proc"); g_proc_bound = 0; }
	if (g_target_mounted) { unmount_best_effort(TARGET_MNT); g_target_mounted = 0; }
}

static void die(const char *fmt, ...) __attribute__((noreturn));
static void die(const char *fmt, ...) {
	va_list ap;
	/* endwin() may not have been called yet if die() fires while still in
	 * the TUI (e.g. a setup failure before install even starts) -- calling
	 * it twice is harmless, and isendwin() lets us skip it if we're already
	 * in plain-terminal mode during the install phase. */
	if (!isendwin()) endwin();
	fprintf(stderr, "florainstall: FATAL: ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	cleanup_mounts();
	exit(1);
}

/* --- child-process helpers: every external tool this project already
 * ships (sfdisk, mkfs.btrfs, rsync, blkid, wipefs, fau, florauser,
 * grub-install) is run via fork+exec, matching fau's own philosophy of
 * calling real tools rather than reimplementing them, while chroot(2)/
 * mount(2) themselves are plain direct syscalls (same level as floraseat's
 * own raw syscall use) rather than shelling out to /usr/bin/mount or
 * /usr/sbin/chroot. --- */

static int run_argv(char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) die("fork failed: %s", strerror(errno));
	if (pid == 0) {
		execvp(argv[0], argv);
		fprintf(stderr, "florainstall: exec %s failed: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	int status;
	if (waitpid(pid, &status, 0) < 0) die("waitpid failed: %s", strerror(errno));
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	return -1;
}

static void run_argv_or_die(char *const argv[]) {
	int rc = run_argv(argv);
	if (rc != 0) die("%s exited with status %d", argv[0], rc);
}

/* Feeds `input` to the child's stdin (used for sfdisk's script format) then
 * waits for it. */
static void run_argv_input_or_die(char *const argv[], const char *input) {
	int pipefd[2];
	if (pipe(pipefd) != 0) die("pipe failed: %s", strerror(errno));
	pid_t pid = fork();
	if (pid < 0) die("fork failed: %s", strerror(errno));
	if (pid == 0) {
		dup2(pipefd[0], STDIN_FILENO);
		close(pipefd[0]);
		close(pipefd[1]);
		execvp(argv[0], argv);
		fprintf(stderr, "florainstall: exec %s failed: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	close(pipefd[0]);
	if (write(pipefd[1], input, strlen(input)) < 0) { /* child will report its own error */ }
	close(pipefd[1]);
	int status;
	waitpid(pid, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		die("%s failed (see output above)", argv[0]);
}

/* Captures the child's stdout (used for `blkid -s UUID -o value`). Trims
 * the trailing newline. Dies if the child produced nothing usable. */
static void run_argv_capture_or_die(char *const argv[], char *out, size_t outsz) {
	int pipefd[2];
	if (pipe(pipefd) != 0) die("pipe failed: %s", strerror(errno));
	pid_t pid = fork();
	if (pid < 0) die("fork failed: %s", strerror(errno));
	if (pid == 0) {
		dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[0]);
		close(pipefd[1]);
		execvp(argv[0], argv);
		fprintf(stderr, "florainstall: exec %s failed: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	close(pipefd[1]);
	size_t used = 0;
	ssize_t n;
	memset(out, 0, outsz);
	while (used + 1 < outsz && (n = read(pipefd[0], out + used, outsz - 1 - used)) > 0)
		used += (size_t)n;
	close(pipefd[0]);
	int status;
	waitpid(pid, &status, 0);
	while (used > 0 && (out[used - 1] == '\n' || out[used - 1] == '\r')) out[--used] = 0;
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || used == 0)
		die("%s produced no output -- can't continue without it", argv[0]);
}

/* Runs one program inside a chroot at `root`. A fresh fork per call (rather
 * than chroot()-ing this whole process) so each in-chroot step is fully
 * isolated and the parent's own view of "/" never changes. stdio is
 * inherited on purpose: florauser's own interactive password prompt needs
 * the real terminal, not a captured pipe. */
static void run_in_chroot_or_die(const char *root, char *const argv[]) {
	pid_t pid = fork();
	if (pid < 0) die("fork failed: %s", strerror(errno));
	if (pid == 0) {
		if (chroot(root) != 0) { fprintf(stderr, "florainstall: chroot failed: %s\n", strerror(errno)); _exit(127); }
		if (chdir("/") != 0) { fprintf(stderr, "florainstall: chdir failed: %s\n", strerror(errno)); _exit(127); }
		execvp(argv[0], argv);
		fprintf(stderr, "florainstall: exec %s (chrooted) failed: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	int status;
	waitpid(pid, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		die("%s failed inside the target chroot", argv[0]);
}

/* --- disk enumeration: reads /sys/block directly (same "read the real
 * kernel-provided data, don't rely on a wrapper" convention florauser uses
 * for /etc/passwd instead of getpwnam) rather than parsing lsblk output. */

static int is_whole_disk(const char *name) {
	if (strncmp(name, "loop", 4) == 0) return 0;
	if (strncmp(name, "sr", 2) == 0) return 0;
	if (strncmp(name, "ram", 3) == 0) return 0;
	return 1;
}

static int list_disks(struct disk_info *out, int max) {
	DIR *d = opendir("/sys/block");
	if (!d) die("can't read /sys/block: %s", strerror(errno));
	int n = 0;
	struct dirent *ent;
	while (n < max && (ent = readdir(d)) != NULL) {
		if (ent->d_name[0] == '.') continue;
		if (!is_whole_disk(ent->d_name)) continue;
		char sizepath[300];
		snprintf(sizepath, sizeof(sizepath), "/sys/block/%s/size", ent->d_name);
		FILE *f = fopen(sizepath, "r");
		if (!f) continue;
		unsigned long long sectors = 0;
		if (fscanf(f, "%llu", &sectors) != 1) sectors = 0;
		fclose(f);
		if (sectors == 0) continue; /* empty drive (e.g. no media in a card reader) */
		snprintf(out[n].name, sizeof(out[n].name), "%s", ent->d_name);
		snprintf(out[n].path, sizeof(out[n].path), "/dev/%s", ent->d_name);
		out[n].bytes = sectors * 512ULL;
		n++;
	}
	closedir(d);
	return n;
}

/* "sda" -> partition 1 is "/dev/sda1"; "nvme0n1"/"mmcblk0" -> "p1" infix,
 * since their own device names already end in a digit. */
static void partition_path(const struct disk_info *disk, int partnum, char *out, size_t outsz) {
	size_t len = strlen(disk->name);
	int needs_p = len > 0 && isdigit((unsigned char)disk->name[len - 1]);
	snprintf(out, outsz, "%s%s%d", disk->path, needs_p ? "p" : "", partnum);
}

/* --- ncurses TUI helpers --- */

static void init_tui(void) {
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	curs_set(0);
}

/* Simple scrolling list picker built on <menu.h> -- returns the chosen
 * index, or -1 if the user backs out with 'q'/ESC. */
static int run_choice_menu(const char *title, const char *const *labels, int n) {
	ITEM **items = calloc((size_t)n + 1, sizeof(ITEM *));
	for (int i = 0; i < n; i++) items[i] = new_item(labels[i], "");
	items[n] = NULL;

	MENU *menu = new_menu(items);
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	int height = n + 4 < rows - 4 ? n + 4 : rows - 4;
	if (height < 6) height = 6;
	int width = cols - 10 > 20 ? cols - 10 : 20;
	WINDOW *win = newwin(height, width, (rows - height) / 2, (cols - width) / 2);
	keypad(win, TRUE);
	set_menu_win(menu, win);
	set_menu_sub(menu, derwin(win, height - 4, width - 2, 3, 1));
	set_menu_format(menu, height - 4, 1);
	set_menu_mark(menu, "> ");
	box(win, 0, 0);
	mvwprintw(win, 1, 2, "%.*s", width - 4, title);
	mvwprintw(win, height - 1, 2, "Enter=select  q/ESC=back");
	post_menu(menu);
	wrefresh(win);

	int result = -1;
	int ch;
	while ((ch = wgetch(win)) != ERR) {
		switch (ch) {
		case KEY_DOWN: menu_driver(menu, REQ_DOWN_ITEM); break;
		case KEY_UP: menu_driver(menu, REQ_UP_ITEM); break;
		case KEY_NPAGE: menu_driver(menu, REQ_SCR_DPAGE); break;
		case KEY_PPAGE: menu_driver(menu, REQ_SCR_UPAGE); break;
		case '\n': case KEY_ENTER:
			result = item_index(current_item(menu));
			goto done;
		case 'q': case 27: /* ESC */
			result = -1;
			goto done;
		default: break;
		}
		wrefresh(win);
	}
done:
	unpost_menu(menu);
	free_menu(menu);
	for (int i = 0; i < n; i++) free_item(items[i]);
	free(items);
	delwin(win);
	touchwin(stdscr);
	refresh();
	return result;
}

/* Freeform text entry in a small centered box. Leaves `buf` untouched (and
 * returns 0) if the user backs out with ESC before typing anything;
 * otherwise writes the typed line (possibly empty) and returns 1.
 *
 * Hand-rolled character loop rather than mvwgetnstr(): that function has no
 * notion of "cancel" at all, so despite the "ESC=cancel" hint printed below,
 * ESC used to just be handed to it as a plain data byte -- and because this
 * window has keypad(TRUE) set (needed for backspace), ncurses would first
 * hold it for the ESCDELAY timeout (~1s) waiting to see if it was the start
 * of a function-key sequence, then insert byte 0x1b into the buffer. Reading
 * input a key at a time here lets ESC actually abort immediately, the same
 * way run_choice_menu()'s own loop already handles it. */
static int prompt_text(const char *title, const char *prompt, char *buf, size_t bufsz) {
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	int height = 7, width = cols - 10 > 40 ? cols - 10 : 40;
	WINDOW *win = newwin(height, width, (rows - height) / 2, (cols - width) / 2);
	keypad(win, TRUE);
	box(win, 0, 0);
	mvwprintw(win, 1, 2, "%.*s", width - 4, title);
	mvwprintw(win, 3, 2, "%.*s", width - 4, prompt);
	mvwprintw(win, 5, 2, "Enter=confirm  ESC=cancel");
	wrefresh(win);

	curs_set(1);
	char tmp[256];
	memset(tmp, 0, sizeof(tmp));
	size_t len = 0;
	size_t maxlen = bufsz - 1 < sizeof(tmp) - 1 ? bufsz - 1 : sizeof(tmp) - 1;
	int field_width = width - 4;
	int cancelled = 0;

	for (;;) {
		mvwprintw(win, 4, 2, "%-*.*s", field_width, field_width, tmp);
		wmove(win, 4, 2 + (int)len);
		wrefresh(win);
		int ch = wgetch(win);
		if (ch == 27) { cancelled = 1; break; }
		if (ch == '\n' || ch == KEY_ENTER) break;
		if (ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
			if (len > 0) tmp[--len] = 0;
			continue;
		}
		if (len < maxlen && ch >= 32 && ch < 127) {
			tmp[len++] = (char)ch;
			tmp[len] = 0;
		}
	}
	curs_set(0);

	delwin(win);
	touchwin(stdscr);
	refresh();

	if (cancelled) return 0;
	snprintf(buf, bufsz, "%s", tmp);
	return 1;
}

static void show_message(const char *title, const char *const *lines, int n) {
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	int height = n + 5, width = cols - 10 > 40 ? cols - 10 : 40;
	if (height > rows - 2) height = rows - 2;
	WINDOW *win = newwin(height, width, (rows - height) / 2, (cols - width) / 2);
	box(win, 0, 0);
	mvwprintw(win, 1, 2, "%.*s", width - 4, title);
	for (int i = 0; i < n && i + 3 < height - 2; i++)
		mvwprintw(win, i + 3, 2, "%.*s", width - 4, lines[i]);
	mvwprintw(win, height - 2, 2, "Press any key...");
	wrefresh(win);
	wgetch(win);
	delwin(win);
	touchwin(stdscr);
	refresh();
}

/* Requires the user to type the disk's own short name (e.g. "sda") back
 * exactly, the same "type the thing you're about to destroy" confirmation
 * pattern real installers use -- a plain y/n is too easy to reflexively
 * confirm for an operation this destructive. */
static int confirm_destructive(const struct install_settings *s) {
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	int height = 10, width = cols - 10 > 50 ? cols - 10 : 50;
	WINDOW *win = newwin(height, width, (rows - height) / 2, (cols - width) / 2);
	keypad(win, TRUE);
	box(win, 0, 0);
	mvwprintw(win, 1, 2, "WARNING: this ERASES %s entirely", s->disk.path);
	mvwprintw(win, 2, 2, "(%llu MiB), including any other OS on it.", s->disk.bytes / (1024 * 1024));
	mvwprintw(win, 4, 2, "Type \"%s\" (without quotes) to proceed:", s->disk.name);
	mvwprintw(win, 6, 2, "Anything else cancels.");
	wrefresh(win);

	curs_set(1);
	echo();
	char typed[64];
	memset(typed, 0, sizeof(typed));
	mvwgetnstr(win, 5, 2, typed, (int)sizeof(typed) - 1);
	noecho();
	curs_set(0);
	delwin(win);
	touchwin(stdscr);
	refresh();

	return strcmp(typed, s->disk.name) == 0;
}

/* --- main settings menu --- */

static void format_disk_label(const struct disk_info *d, char *out, size_t outsz) {
	double gib = (double)d->bytes / (1024.0 * 1024.0 * 1024.0);
	snprintf(out, outsz, "%s (%.1f GiB)", d->path, gib);
}

static void pick_disk(struct install_settings *s) {
	struct disk_info disks[64];
	int n = list_disks(disks, 64);
	if (n == 0) {
		const char *lines[] = {"No disks found under /sys/block."};
		show_message("No disks", lines, 1);
		return;
	}
	char labels_buf[64][300];
	const char *labels[64];
	for (int i = 0; i < n; i++) {
		format_disk_label(&disks[i], labels_buf[i], sizeof(labels_buf[i]));
		labels[i] = labels_buf[i];
	}
	int choice = run_choice_menu("Select target disk", labels, n);
	if (choice >= 0) s->disk = disks[choice];
}

/* Runs the whole disk-destroying install pipeline. Called only after
 * confirm_destructive() has already returned true. Leaves curses mode
 * permanently (this is a one-shot linear operation, not something you
 * back out of into the menu again) and logs plainly to the terminal, the
 * same style build-rootfs.sh's own log() uses. */
static void do_install(const struct install_settings *s) {
	endwin();

	log_msg("wiping old signatures on %s", s->disk.path);
	run_argv_or_die((char *[]){"wipefs", "-a", (char *)s->disk.path, NULL});

	log_msg("partitioning %s (MBR, one bootable Linux partition)", s->disk.path);
	run_argv_input_or_die((char *[]){"sfdisk", (char *)s->disk.path, NULL},
		"label: dos\n\ntype=83, bootable\n");

	/* sfdisk already re-reads the partition table via BLKRRPART itself on
	 * a clean write, but doing it explicitly here too is cheap insurance --
	 * confirmed necessary in practice on some kernel/udev timing (the
	 * device node for the new partition can otherwise still be missing by
	 * the time the next step opens it). */
	int fd = open(s->disk.path, O_RDONLY);
	if (fd >= 0) { ioctl(fd, BLKRRPART, NULL); close(fd); }

	char part1[300];
	partition_path(&s->disk, 1, part1, sizeof(part1));
	for (int tries = 0; tries < 50; tries++) {
		struct stat st;
		if (stat(part1, &st) == 0) break;
		usleep(100000);
	}
	struct stat st;
	if (stat(part1, &st) != 0)
		die("partition device %s never appeared -- check `sfdisk -l %s`", part1, s->disk.path);

	log_msg("fetching btrfs-progs (via fau's own alpm fallback, onto the live system itself)");
	{
		/* Unlike grub below, mkfs.btrfs has to run *before* the target
		 * disk has anything mounted on it at all, so this bootstraps
		 * onto the live "/" (FAU_ROOT left at its own default) rather
		 * than the target -- fau's own --help documents this as a
		 * supported, intended use (`FAU_ROOT target root for bootstrap
		 * package(s) (default: /)`), not a build-time-only path. */
		pid_t pid = fork();
		if (pid < 0) die("fork failed: %s", strerror(errno));
		if (pid == 0) {
			execlp("fau", "fau", "bootstrap", "btrfs-progs", (char *)NULL);
			fprintf(stderr, "florainstall: exec fau failed: %s\n", strerror(errno));
			_exit(127);
		}
		int status;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
			die("fetching btrfs-progs failed -- check network connectivity (dhcpcd should already be up)");
	}

	log_msg("formatting %s as btrfs", part1);
	run_argv_or_die((char *[]){"mkfs.btrfs", "-f", "-L", "floraos", part1, NULL});

	log_msg("mounting %s at " TARGET_MNT, part1);
	mkdir(TARGET_MNT, 0755);
	if (mount(part1, TARGET_MNT, "btrfs", 0, NULL) != 0)
		die("mount %s -> " TARGET_MNT " failed: %s", part1, strerror(errno));
	g_target_mounted = 1;

	log_msg("copying the running system onto the target disk (this takes a while)");
	run_argv_or_die((char *[]){"rsync", "-aHAX",
		"--exclude=/proc", "--exclude=/sys", "--exclude=/dev",
		"--exclude=/run", "--exclude=/tmp", "--exclude=/mnt",
		"/", TARGET_MNT "/", NULL});
	/* rsync excluded these on purpose (they're runtime-populated
	 * mountpoints, not real content) -- recreate them as empty dirs so
	 * the installed system's own /etc/inittab (copied verbatim above) has
	 * somewhere to mount onto at boot, same as the live rootfs build
	 * itself provides. */
	{
		const char *dirs[] = {"proc", "sys", "dev", "run", "tmp"};
		for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
			char p[256];
			snprintf(p, sizeof(p), TARGET_MNT "/%s", dirs[i]);
			mkdir(p, 0755);
		}
	}

	log_msg("copying the kernel image onto the target");
	if (stat(LIVE_KERNEL_PATH, &st) != 0)
		die("no kernel image at %s -- this live image wasn't built with florainstall support "
		    "(see build-rootfs.sh's /usr/lib/floraos staging step)", LIVE_KERNEL_PATH);
	mkdir(TARGET_MNT "/boot", 0755);
	run_argv_or_die((char *[]){"cp", "-a", LIVE_KERNEL_PATH, TARGET_MNT "/boot/vmlinuz-floraos", NULL});

	char uuid[64];
	run_argv_capture_or_die((char *[]){"blkid", "-s", "UUID", "-o", "value", part1, NULL}, uuid, sizeof(uuid));

	log_msg("writing /etc/fstab");
	{
		FILE *f = fopen(TARGET_MNT "/etc/fstab", "w");
		if (!f) die("can't write " TARGET_MNT "/etc/fstab: %s", strerror(errno));
		fprintf(f, "UUID=%s / btrfs defaults 0 1\n", uuid);
		fclose(f);
	}

	if (s->hostname[0]) {
		log_msg("setting hostname to %s", s->hostname);
		FILE *f = fopen(TARGET_MNT "/etc/hostname", "w");
		if (f) { fprintf(f, "%s\n", s->hostname); fclose(f); }
		f = fopen(TARGET_MNT "/etc/conf.d/hostname", "w");
		if (f) { fprintf(f, "hostname=\"%s\"\n", s->hostname); fclose(f); }
	}

	log_msg("fetching grub (via fau's own alpm fallback, into the target only)");
	{
		pid_t pid = fork();
		if (pid < 0) die("fork failed: %s", strerror(errno));
		if (pid == 0) {
			setenv("FAU_ROOT", TARGET_MNT, 1);
			execlp("fau", "fau", "bootstrap", "grub", (char *)NULL);
			fprintf(stderr, "florainstall: exec fau failed: %s\n", strerror(errno));
			_exit(127);
		}
		int status;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
			die("fetching grub failed -- check network connectivity (dhcpcd should already be up)");
	}

	log_msg("binding /dev, /proc, /sys into the target for the chroot steps");
	mkdir(TARGET_MNT "/dev", 0755);
	mkdir(TARGET_MNT "/proc", 0755);
	mkdir(TARGET_MNT "/sys", 0755);
	if (mount("/dev", TARGET_MNT "/dev", NULL, MS_BIND, NULL) != 0)
		die("bind-mount /dev failed: %s", strerror(errno));
	g_dev_bound = 1;
	if (mount("/sys", TARGET_MNT "/sys", NULL, MS_BIND, NULL) != 0)
		die("bind-mount /sys failed: %s", strerror(errno));
	g_sys_bound = 1;
	if (mount("proc", TARGET_MNT "/proc", "proc", 0, NULL) != 0)
		die("mount proc failed: %s", strerror(errno));
	g_proc_bound = 1;

	log_msg("installing grub to %s (BIOS/i386-pc)", s->disk.path);
	run_in_chroot_or_die(TARGET_MNT,
		(char *[]){"grub-install", "--target=i386-pc", "--boot-directory=/boot", (char *)s->disk.path, NULL});

	log_msg("writing /boot/grub/grub.cfg");
	{
		char path[256];
		snprintf(path, sizeof(path), TARGET_MNT "/boot/grub/grub.cfg");
		FILE *f = fopen(path, "w");
		if (!f) die("can't write %s: %s", path, strerror(errno));
		/* No initrd line: unlike the live ISO (which boots by unpacking its
		 * whole rootfs as an initramfs), this is a real disk root -- the
		 * kernel mounts btrfs directly. Assumes CONFIG_BTRFS_FS=y (built
		 * in, not a module) in this kernel's defconfig -- now explicitly
		 * enabled in scripts/recipes/linux-lts.sh; see this file's header
		 * comment for why that's still not independently confirmed by an
		 * actual kernel build in this sandbox. */
		fprintf(f,
			"set default=0\n"
			"set timeout=3\n"
			"insmod part_msdos\n"
			"insmod btrfs\n"
			"search --no-floppy --fs-uuid --set=root %s\n"
			"menuentry \"FloraOS\" {\n"
			"\tlinux /boot/vmlinuz-floraos root=UUID=%s rootfstype=btrfs ro console=tty0 console=ttyS0\n"
			"}\n",
			uuid, uuid);
		fclose(f);
	}

	log_msg("setting the root password (via florauser, inside the target)");
	run_in_chroot_or_die(TARGET_MNT, (char *[]){"florauser", "passwd", "root", NULL});

	if (s->create_user && s->username[0]) {
		log_msg("creating user %s (via florauser, inside the target)", s->username);
		run_in_chroot_or_die(TARGET_MNT,
			(char *[]){"florauser", "add", (char *)s->username,
				s->groups[0] ? (char *)s->groups : NULL, NULL});
		log_msg("setting %s's password", s->username);
		run_in_chroot_or_die(TARGET_MNT, (char *[]){"florauser", "passwd", (char *)s->username, NULL});
	}

	log_msg("unmounting");
	cleanup_mounts();

	log_msg("done. Remove the installation media and reboot into %s.", s->disk.path);
}

/* --- main menu loop --- */

static void main_menu(struct install_settings *s) {
	for (;;) {
		char disk_label[300], user_label[192];
		if (s->disk.name[0]) format_disk_label(&s->disk, disk_label, sizeof(disk_label));
		else snprintf(disk_label, sizeof(disk_label), "(not selected)");
		if (s->create_user && s->username[0])
			snprintf(user_label, sizeof(user_label), "%s%s%s", s->username,
				s->groups[0] ? " / groups: " : "", s->groups[0] ? s->groups : "");
		else
			snprintf(user_label, sizeof(user_label), "(none)");

		char item0[340], item1[96], item2[320];
		snprintf(item0, sizeof(item0), "Target disk: %s", disk_label);
		snprintf(item1, sizeof(item1), "Hostname: %s", s->hostname);
		snprintf(item2, sizeof(item2), "Additional user: %s", user_label);
		const char *labels[] = {
			item0, item1, item2,
			"Begin installation",
			"Quit without installing",
		};
		int choice = run_choice_menu("florainstall -- FloraOS disk installer", labels, 5);

		switch (choice) {
		case 0:
			pick_disk(s);
			break;
		case 1: {
			char buf[64];
			snprintf(buf, sizeof(buf), "%s", s->hostname);
			prompt_text("Hostname", "New hostname:", buf, sizeof(buf));
			if (buf[0]) snprintf(s->hostname, sizeof(s->hostname), "%s", buf);
			break;
		}
		case 2: {
			char buf[32];
			buf[0] = 0;
			prompt_text("Additional user", "Username (blank = don't create one):", buf, sizeof(buf));
			if (buf[0]) {
				snprintf(s->username, sizeof(s->username), "%s", buf);
				s->create_user = 1;
				char groupbuf[128];
				snprintf(groupbuf, sizeof(groupbuf), "%s", s->groups);
				prompt_text("Additional user", "Extra groups, comma-separated (e.g. seat), or blank:",
					groupbuf, sizeof(groupbuf));
				snprintf(s->groups, sizeof(s->groups), "%s", groupbuf);
			} else {
				s->create_user = 0;
				s->username[0] = 0;
				s->groups[0] = 0;
			}
			break;
		}
		case 3:
			if (!s->disk.name[0]) {
				const char *lines[] = {"Pick a target disk first."};
				show_message("Nothing to install to", lines, 1);
				break;
			}
			if (!confirm_destructive(s)) {
				const char *lines[] = {"Cancelled -- disk left untouched."};
				show_message("Cancelled", lines, 1);
				break;
			}
			do_install(s);
			return; /* do_install() already left curses mode for good */
		case 4:
		case -1:
			endwin();
			return;
		}
	}
}

int main(int argc, char **argv) {
	if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
		printf("florainstall -- install FloraOS to a real disk (TUI, no arguments)\n");
		return 0;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "florainstall: must be run as root\n");
		return 1;
	}

	struct install_settings s;
	memset(&s, 0, sizeof(s));
	{
		FILE *f = fopen("/etc/hostname", "r");
		if (f) {
			if (fscanf(f, "%63s", s.hostname) != 1) s.hostname[0] = 0;
			fclose(f);
		}
	}
	if (!s.hostname[0]) snprintf(s.hostname, sizeof(s.hostname), "floraos");

	init_tui();
	main_menu(&s);
	return 0;
}
