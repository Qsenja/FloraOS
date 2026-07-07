/* florainstall -- FloraOS's own TUI disk installer. See florainstall.md. */
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

#ifndef BLKRRPART /* hand-computed, not from <linux/fs.h> -- see florainstall.md */
#define BLKRRPART 0x125f
#endif

#define TARGET_MNT "/mnt/florainstall"
#define LIVE_KERNEL_PATH "/usr/lib/floraos/vmlinuz-floraos"

#define ESP_SIZE_MIB 512
#define STANDARD_USER_GROUPS "seat"
#define GRUB_PREFETCH_ROOT "/tmp/florainstall-grub-prefetch"

struct disk_info {
	char name[256];
	char path[280];
	unsigned long long bytes;
};

struct install_settings {
	struct disk_info disk;
	char hostname[64];
	int create_user;
	char username[32];
	char groups[128];
};

static int g_target_mounted = 0;
static int g_esp_mounted = 0;
static int g_dev_bound = 0;
static int g_sys_bound = 0;
static int g_proc_bound = 0;

static int g_uefi = 0;

static pid_t g_prefetch_btrfs_pid = -1;
static pid_t g_prefetch_grub_pid = -1;
static pid_t g_prefetch_dosfstools_pid = -1;

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

static void cleanup_mounts(void) {
	if (g_dev_bound) { unmount_best_effort(TARGET_MNT "/dev"); g_dev_bound = 0; }
	if (g_sys_bound) { unmount_best_effort(TARGET_MNT "/sys"); g_sys_bound = 0; }
	if (g_proc_bound) { unmount_best_effort(TARGET_MNT "/proc"); g_proc_bound = 0; }
	if (g_esp_mounted) { unmount_best_effort(TARGET_MNT "/boot/efi"); g_esp_mounted = 0; }
	if (g_target_mounted) { unmount_best_effort(TARGET_MNT); g_target_mounted = 0; }
}

static void die(const char *fmt, ...) __attribute__((noreturn));
static void die(const char *fmt, ...) {
	va_list ap;
	if (!isendwin()) endwin();
	fprintf(stderr, "florainstall: FATAL: ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	cleanup_mounts();
	exit(1);
}

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
	if (write(pipefd[1], input, strlen(input)) < 0) { }
	close(pipefd[1]);
	int status;
	waitpid(pid, &status, 0);
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		die("%s failed (see output above)", argv[0]);
}

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

static pid_t spawn_prefetch(const char *pkg, const char *fau_root) {
	pid_t pid = fork();
	if (pid < 0) return -1;
	if (pid == 0) {
		if (fau_root) setenv("FAU_ROOT", fau_root, 1);
		int devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) { dup2(devnull, STDOUT_FILENO); dup2(devnull, STDERR_FILENO); close(devnull); }
		execlp("fau", "fau", "bootstrap", pkg, (char *)NULL);
		_exit(127);
	}
	return pid;
}

static void reap_prefetch(pid_t *pid) {
	if (*pid <= 0) return;
	int status;
	waitpid(*pid, &status, 0);
	*pid = -1;
}

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
		if (sectors == 0) continue;
		snprintf(out[n].name, sizeof(out[n].name), "%s", ent->d_name);
		snprintf(out[n].path, sizeof(out[n].path), "/dev/%s", ent->d_name);
		out[n].bytes = sectors * 512ULL;
		n++;
	}
	closedir(d);
	return n;
}

static void partition_path(const struct disk_info *disk, int partnum, char *out, size_t outsz) {
	size_t len = strlen(disk->name);
	int needs_p = len > 0 && isdigit((unsigned char)disk->name[len - 1]);
	snprintf(out, outsz, "%s%s%d", disk->path, needs_p ? "p" : "", partnum);
}

static void init_tui(void) {
	initscr();
	cbreak();
	noecho();
	keypad(stdscr, TRUE);
	curs_set(0);
}

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
		case 'q': case 27:
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

/* hand-rolled input loop, not mvwgetnstr() -- see florainstall.md */
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

static int confirm_destructive(const struct install_settings *s) {
	int rows, cols;
	getmaxyx(stdscr, rows, cols);
	int height = 11, width = cols - 10 > 50 ? cols - 10 : 50;
	WINDOW *win = newwin(height, width, (rows - height) / 2, (cols - width) / 2);
	keypad(win, TRUE);
	box(win, 0, 0);
	mvwprintw(win, 1, 2, "WARNING: this ERASES %s entirely", s->disk.path);
	mvwprintw(win, 2, 2, "(%llu MiB), including any other OS on it.", s->disk.bytes / (1024 * 1024));
	mvwprintw(win, 3, 2, "Boot mode detected: %s%s", g_uefi ? "UEFI" : "BIOS (legacy)",
		g_uefi ? " (will create an EFI System Partition)" : "");
	mvwprintw(win, 5, 2, "Type \"%s\" (without quotes) to proceed:", s->disk.name);
	mvwprintw(win, 7, 2, "Anything else cancels.");
	wrefresh(win);

	curs_set(1);
	echo();
	char typed[64];
	memset(typed, 0, sizeof(typed));
	mvwgetnstr(win, 6, 2, typed, (int)sizeof(typed) - 1);
	noecho();
	curs_set(0);
	delwin(win);
	touchwin(stdscr);
	refresh();

	return strcmp(typed, s->disk.name) == 0;
}

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

static void do_install(const struct install_settings *s) {
	endwin();

	log_msg("boot mode detected: %s", g_uefi ? "UEFI" : "BIOS (legacy)");

	log_msg("wiping old signatures on %s", s->disk.path);
	run_argv_or_die((char *[]){"wipefs", "-a", (char *)s->disk.path, NULL});

	char root_part[300], esp_part[300];
	int root_partnum;
	if (g_uefi) {
		log_msg("partitioning %s (MBR: %dMiB ESP + Linux root)", s->disk.path, ESP_SIZE_MIB);
		char script[128];
		snprintf(script, sizeof(script), "label: dos\n\nsize=%dMiB, type=ef\ntype=83\n", ESP_SIZE_MIB);
		run_argv_input_or_die((char *[]){"sfdisk", (char *)s->disk.path, NULL}, script);
		root_partnum = 2;
		partition_path(&s->disk, 1, esp_part, sizeof(esp_part));
	} else {
		log_msg("partitioning %s (MBR, one bootable Linux partition)", s->disk.path);
		run_argv_input_or_die((char *[]){"sfdisk", (char *)s->disk.path, NULL},
			"label: dos\n\ntype=83, bootable\n");
		root_partnum = 1;
		esp_part[0] = 0;
	}

	int fd = open(s->disk.path, O_RDONLY);
	if (fd >= 0) { ioctl(fd, BLKRRPART, NULL); close(fd); }

	struct stat st;
	partition_path(&s->disk, root_partnum, root_part, sizeof(root_part));
	const char *wait_paths[2] = {root_part, g_uefi ? esp_part : NULL};
	for (int w = 0; w < 2; w++) {
		if (!wait_paths[w]) continue;
		int found = 0;
		for (int tries = 0; tries < 50; tries++) {
			if (stat(wait_paths[w], &st) == 0) { found = 1; break; }
			usleep(100000);
		}
		if (!found)
			die("partition device %s never appeared -- check `sfdisk -l %s`", wait_paths[w], s->disk.path);
	}

	if (g_uefi) {
		reap_prefetch(&g_prefetch_dosfstools_pid);
		log_msg("fetching dosfstools (via fau's own alpm fallback, onto the live system itself)");
		{
			pid_t pid = fork();
			if (pid < 0) die("fork failed: %s", strerror(errno));
			if (pid == 0) {
				execlp("fau", "fau", "bootstrap", "dosfstools", (char *)NULL);
				fprintf(stderr, "florainstall: exec fau failed: %s\n", strerror(errno));
				_exit(127);
			}
			int status;
			waitpid(pid, &status, 0);
			if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
				die("fetching dosfstools failed -- check network connectivity (dhcpcd should already be up)");
		}
		log_msg("formatting %s as FAT32 (ESP)", esp_part);
		run_argv_or_die((char *[]){"mkfs.fat", "-F32", "-n", "FLORAESP", esp_part, NULL});
	}

	reap_prefetch(&g_prefetch_btrfs_pid);
	log_msg("fetching btrfs-progs (via fau's own alpm fallback, onto the live system itself)");
	{
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

	log_msg("formatting %s as btrfs", root_part);
	run_argv_or_die((char *[]){"mkfs.btrfs", "-f", "-L", "floraos", root_part, NULL});

	log_msg("mounting %s at " TARGET_MNT " to create the @ subvolume", root_part);
	mkdir(TARGET_MNT, 0755);
	if (mount(root_part, TARGET_MNT, "btrfs", 0, NULL) != 0)
		die("mount %s -> " TARGET_MNT " failed: %s", root_part, strerror(errno));
	g_target_mounted = 1;

	log_msg("creating the @ subvolume");
	run_argv_or_die((char *[]){"btrfs", "subvolume", "create", TARGET_MNT "/@", NULL});
	log_msg("remounting %s (subvol=@) at " TARGET_MNT, root_part);
	if (umount(TARGET_MNT) != 0)
		die("umount " TARGET_MNT " failed: %s", strerror(errno));
	g_target_mounted = 0;
	if (mount(root_part, TARGET_MNT, "btrfs", 0, "subvol=@") != 0)
		die("mount %s -> " TARGET_MNT " (subvol=@) failed: %s", root_part, strerror(errno));
	g_target_mounted = 1;

	log_msg("copying the running system onto the target disk (this takes a while)");
	run_argv_or_die((char *[]){"rsync", "-aHAX",
		"--exclude=/proc", "--exclude=/sys", "--exclude=/dev",
		"--exclude=/run", "--exclude=/tmp", "--exclude=/mnt",
		"/", TARGET_MNT "/", NULL});
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

	char esp_uuid[64] = {0};
	if (g_uefi) {
		log_msg("mounting the ESP at " TARGET_MNT "/boot/efi");
		mkdir(TARGET_MNT "/boot/efi", 0755);
		if (mount(esp_part, TARGET_MNT "/boot/efi", "vfat", 0, NULL) != 0)
			die("mount %s -> " TARGET_MNT "/boot/efi failed: %s", esp_part, strerror(errno));
		g_esp_mounted = 1;
		run_argv_capture_or_die((char *[]){"blkid", "-s", "UUID", "-o", "value", esp_part, NULL},
			esp_uuid, sizeof(esp_uuid));
	}

	char uuid[64];
	run_argv_capture_or_die((char *[]){"blkid", "-s", "UUID", "-o", "value", root_part, NULL}, uuid, sizeof(uuid));

	log_msg("writing /etc/fstab");
	{
		FILE *f = fopen(TARGET_MNT "/etc/fstab", "w");
		if (!f) die("can't write " TARGET_MNT "/etc/fstab: %s", strerror(errno));
		fprintf(f, "UUID=%s / btrfs subvol=@,defaults 0 1\n", uuid);
		if (g_uefi) fprintf(f, "UUID=%s /boot/efi vfat defaults 0 2\n", esp_uuid);
		fclose(f);
	}

	if (s->hostname[0]) {
		log_msg("setting hostname to %s", s->hostname);
		FILE *f = fopen(TARGET_MNT "/etc/hostname", "w");
		if (f) { fprintf(f, "%s\n", s->hostname); fclose(f); }
		f = fopen(TARGET_MNT "/etc/conf.d/hostname", "w");
		if (f) { fprintf(f, "hostname=\"%s\"\n", s->hostname); fclose(f); }
	}

	reap_prefetch(&g_prefetch_grub_pid);
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

	if (g_uefi) {
		log_msg("installing grub to %s (UEFI/x86_64-efi, removable fallback path)", s->disk.path);
		run_in_chroot_or_die(TARGET_MNT,
			(char *[]){"grub-install", "--target=x86_64-efi", "--efi-directory=/boot/efi",
				"--boot-directory=/boot", "--removable", NULL});
	} else {
		log_msg("installing grub to %s (BIOS/i386-pc)", s->disk.path);
		run_in_chroot_or_die(TARGET_MNT,
			(char *[]){"grub-install", "--target=i386-pc", "--boot-directory=/boot", (char *)s->disk.path, NULL});
	}

	log_msg("writing /boot/grub/grub.cfg");
	{
		char path[256];
		snprintf(path, sizeof(path), TARGET_MNT "/boot/grub/grub.cfg");
		run_argv_or_die((char *[]){"floragrub-cfg", (char *)root_part, uuid, path, NULL});
	}

	log_msg("setting the root password (via florauser, inside the target)");
	run_in_chroot_or_die(TARGET_MNT, (char *[]){"florauser", "passwd", "root", NULL});

	if (s->create_user && s->username[0]) {
		log_msg("creating user %s (via florauser, inside the target)", s->username);
		run_in_chroot_or_die(TARGET_MNT,
			(char *[]){"florauser", "add", (char *)s->username,
				s->groups[0] ? (char *)s->groups : NULL, NULL});
		log_msg("setting %s's password (leave the first prompt blank to reuse root's password)", s->username);
		run_in_chroot_or_die(TARGET_MNT, (char *[]){"florauser", "passwd", (char *)s->username, NULL});
	}

	log_msg("unmounting");
	cleanup_mounts();

	log_msg("done. Remove the installation media and reboot into %s.", s->disk.path);
}

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
				const char *group_labels[] = {
					"Standard (normal user: " STANDARD_USER_GROUPS " group, for login/GUI)",
					"None (no extra groups)",
					"Custom (type group names yourself)",
				};
				switch (run_choice_menu("Extra groups", group_labels, 3)) {
				case 0:
					snprintf(s->groups, sizeof(s->groups), "%s", STANDARD_USER_GROUPS);
					break;
				case 1:
					s->groups[0] = 0;
					break;
				case 2: {
					char groupbuf[128];
					snprintf(groupbuf, sizeof(groupbuf), "%s", s->groups);
					prompt_text("Additional user", "Extra groups, comma-separated (e.g. seat), or blank:",
						groupbuf, sizeof(groupbuf));
					snprintf(s->groups, sizeof(s->groups), "%s", groupbuf);
					break;
				}
				default:
					break;
				}
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
			return;
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

	g_uefi = access("/sys/firmware/efi", F_OK) == 0;

	g_prefetch_btrfs_pid = spawn_prefetch("btrfs-progs", NULL);
	g_prefetch_grub_pid = spawn_prefetch("grub", GRUB_PREFETCH_ROOT);
	if (g_uefi) g_prefetch_dosfstools_pid = spawn_prefetch("dosfstools", NULL);

	init_tui();
	main_menu(&s);
	return 0;
}
