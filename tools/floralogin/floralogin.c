/* floralogin -- FloraOS's own minimal password-backed login. See floralogin.md. */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <shadow.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>
#include <crypt.h>

#define MAX_LINE 256

/* -1 on EOF must end the program -- see floralogin.md */
static int read_line(char *buf, size_t bufsz) {
	if (!fgets(buf, (int)bufsz, stdin)) {
		buf[0] = '\0';
		return -1;
	}
	buf[strcspn(buf, "\n")] = '\0';
	return 0;
}

static int read_password(char *buf, size_t bufsz) {
	struct termios oldt, newt;
	int have_tty = tcgetattr(STDIN_FILENO, &oldt) == 0;
	if (have_tty) {
		newt = oldt;
		newt.c_lflag &= ~((tcflag_t)ECHO);
		tcsetattr(STDIN_FILENO, TCSANOW, &newt);
	}
	int rc = read_line(buf, bufsz);
	if (have_tty) {
		tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
		putchar('\n');
	}
	return rc;
}

static int password_ok(const struct spwd *sp, const char *password) {
	if (sp->sp_pwdp[0] == '\0') return 1; /* empty hash = no password required, see floralogin.md */
	struct crypt_data data;
	memset(&data, 0, sizeof(data));
	char *hash = crypt_r(password, sp->sp_pwdp, &data);
	return hash && strcmp(hash, sp->sp_pwdp) == 0;
}

int main(void) {
	char username[MAX_LINE];
	char password[MAX_LINE];

	for (;;) {
		printf("floraos login: ");
		fflush(stdout);
		if (read_line(username, sizeof(username)) != 0) return 0;
		if (username[0] == '\0') continue;

		printf("Password: ");
		fflush(stdout);
		if (read_password(password, sizeof(password)) != 0) return 0;

		struct passwd *pw = getpwnam(username);
		struct spwd *sp = pw ? getspnam(username) : NULL;
		int ok = pw && sp && password_ok(sp, password);
		/* explicit_bzero, not memset -- see floralogin.md. */
		explicit_bzero(password, sizeof(password));

		if (!ok) {
			fprintf(stderr, "Login incorrect\n");
			sleep(2);
			continue;
		}

		if (initgroups(pw->pw_name, pw->pw_gid) != 0) {
			perror("floralogin: initgroups");
			return 1;
		}
		if (setgid(pw->pw_gid) != 0) {
			perror("floralogin: setgid");
			return 1;
		}
		if (setuid(pw->pw_uid) != 0) {
			perror("floralogin: setuid");
			return 1;
		}
		if (chdir(pw->pw_dir) != 0) {
			chdir("/");
		}

		/* no session manager to do this for us, see floralogin.md */
		{
			char rundir[64];
			int len = snprintf(rundir, sizeof rundir, "/run/user/%d", (int)pw->pw_uid);
			if (len > 0 && (size_t)len < sizeof rundir) {
				mkdir("/run/user", 0755);
				if (mkdir(rundir, 0700) != 0 && errno != EEXIST) {
					fprintf(stderr, "floralogin: warning: could not create %s: %s\n",
						rundir, strerror(errno));
				} else {
					chown(rundir, pw->pw_uid, pw->pw_gid);
					chmod(rundir, 0700);
					setenv("XDG_RUNTIME_DIR", rundir, 1);
				}
			}
		}

		const char *shell = (pw->pw_shell[0] != '\0') ? pw->pw_shell : "/usr/bin/bash";
		setenv("HOME", pw->pw_dir, 1);
		setenv("USER", pw->pw_name, 1);
		setenv("LOGNAME", pw->pw_name, 1);
		setenv("SHELL", shell, 1);
		setenv("PATH", "/usr/bin", 1);

		const char *base = strrchr(shell, '/');
		base = base ? base + 1 : shell;
		char argv0[MAX_LINE];
		snprintf(argv0, sizeof(argv0), "-%s", base);

		execl(shell, argv0, (char *)NULL);
		perror("floralogin: exec");
		return 1;
	}
}
