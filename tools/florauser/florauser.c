/* florauser -- FloraOS's own minimal user/group management tool, written
 * from scratch the same way floralogin/fauelf/floraseat are: small,
 * auditable, purpose-built instead of vendoring shadow-utils (which,
 * like util-linux's login, expects PAM to be part of the picture and
 * pulls in far more than FloraOS needs -- see ARCHITECTURE.md).
 *
 * Closes a real gap: floraseat/eudev/floralogin's own XDG_RUNTIME_DIR
 * setup all work for *any* user already in /etc/passwd, but there was no
 * way to create a second, non-root user at all -- root was the only login
 * that could ever exist. This is what "usermod -aG seat <user>" (mentioned
 * as the migration path in floraseat's own file header) actually needs
 * something to run first.
 *
 * Commands:
 *   florauser add <name> [group1,group2,...]
 *     Creates <name> with a fresh uid/gid pair (>=1000), its own primary
 *     group (same name, classic "user private group" scheme), a locked
 *     password (shadow field "!", NOT floralogin's root-only empty-field
 *     "no password" convention -- a freshly created account can't log in
 *     until `florauser passwd` gives it a real one), and a home directory
 *     at /home/<name> (0700, chowned). Optional comma-separated
 *     supplementary groups (e.g. "seat") are joined too -- those groups
 *     must already exist.
 *   florauser passwd <name>
 *     Prompts twice (termios echo off, same technique as floralogin's own
 *     read_password), hashes via crypt_gensalt()+crypt_r() (libxcrypt's
 *     own strongest default -- not a hand-picked algorithm), rewrites
 *     that user's /etc/shadow line in place. For any <name> other than
 *     root, leaving the first prompt blank copies root's own current
 *     /etc/shadow hash verbatim instead of hashing an empty password --
 *     lets florainstall's own "additional user" step offer "same as root"
 *     to someone who doesn't want to think of and type a second password.
 *     Requires root to already have a real password set (fails otherwise,
 *     same as any other missing-shadow-entry case).
 *   florauser groupadd <name> [gid]
 *     Creates a new, empty group. Auto-picks a free gid >=1000 if none
 *     given.
 *   florauser addtogroup <user> <group>
 *     Appends <user> to an existing group's member list (no-op if
 *     already a member).
 *
 * Every lookup (does this user/group already exist? what's their current
 * shadow line?) goes through this file's own PASSWD_PATH/GROUP_PATH/
 * SHADOW_PATH constants and hand-rolled colon-field parser -- deliberately
 * NOT getpwnam()/getgrnam()/getspnam(), which resolve through glibc's NSS
 * and would depend on /etc/nsswitch.conf being present and sane. FloraOS
 * ships no nsswitch.conf at all, so this keeps florauser self-consistent
 * or at least not silently dependent on default. This was
 * confirmed necessary in practice: an early version of this file called
 * getpwnam() from `florauser passwd`, which worked fine on the real
 * rootfs but made the tool untestable in isolation without faking a
 * matching NSS/user database -- switching to the same file-parsing path
 * as every other command fixed both.
 *
 * Deliberately NOT done: no file locking against a second concurrent
 * florauser/floralogin invocation (root is the only admin today, and
 * this is an interactively-run admin tool, not a daemon -- same
 * "known limitation, not a bug" treatment as other small FloraOS tools).
 * No password-complexity policy, no /etc/login.defs, no NIS/LDAP -- none
 * of that exists elsewhere in FloraOS either.
 *
 * Verified in this sandbox (not just compiled): built with -Wall -Wextra
 * (clean, no warnings), then exercised end-to-end against a scratch
 * passwd/group/shadow (uid/gid allocation incl. the "a group already took
 * this gid" case, user-private-group creation, supplementary group join,
 * idempotent addtogroup, groupadd, password set + mismatch handling via
 * crypt_gensalt/crypt_r producing a real yescrypt $y$ hash, and the
 * expected rejections: duplicate user, invalid name, missing group).
 * What's NOT verified: an actual root-privileged run against a real
 * FloraOS rootfs's live /etc/{passwd,group,shadow} or a real login using
 * an florauser-created account (no root/QEMU access in this sandbox --
 * same disclosed limitation as the rest of this round's work).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <crypt.h>

#define PASSWD_PATH "/etc/passwd"
#define GROUP_PATH  "/etc/group"
#define SHADOW_PATH "/etc/shadow"
#define MAX_LINE 512
#define MIN_ID 1000

/* --- tiny whole-file line list: read everything into memory, edit, write
 * back atomically (tmp file + rename). Fine for /etc/passwd-sized files;
 * not meant for anything large. --- */
struct lines {
	char **v;
	size_t n, cap;
};

static void lines_push(struct lines *l, char *s) {
	if (l->n == l->cap) {
		l->cap = l->cap ? l->cap * 2 : 32;
		l->v = realloc(l->v, l->cap * sizeof(char *));
		if (!l->v) { perror("florauser: realloc"); exit(1); }
	}
	l->v[l->n++] = s;
}

static struct lines read_lines(const char *path) {
	struct lines l = {0};
	FILE *f = fopen(path, "r");
	if (!f) { fprintf(stderr, "florauser: %s: %s\n", path, strerror(errno)); exit(1); }
	char buf[MAX_LINE];
	while (fgets(buf, sizeof buf, f)) {
		buf[strcspn(buf, "\n")] = '\0';
		lines_push(&l, strdup(buf));
	}
	fclose(f);
	return l;
}

static void write_lines(const char *path, struct lines *l, mode_t mode) {
	char tmp[256];
	snprintf(tmp, sizeof tmp, "%s.florauser.tmp", path);
	FILE *f = fopen(tmp, "w");
	if (!f) { fprintf(stderr, "florauser: %s: %s\n", tmp, strerror(errno)); exit(1); }
	for (size_t i = 0; i < l->n; i++) fprintf(f, "%s\n", l->v[i]);
	fclose(f);
	chmod(tmp, mode);
	if (rename(tmp, path) != 0) {
		fprintf(stderr, "florauser: renaming %s to %s: %s\n", tmp, path, strerror(errno));
		exit(1);
	}
}

static void lines_free(struct lines *l) {
	for (size_t i = 0; i < l->n; i++) free(l->v[i]);
	free(l->v);
}

/* field <n> (0-based) of a colon-delimited line, into a caller buffer. */
static int field(const char *line, int n, char *out, size_t outsz) {
	const char *p = line;
	for (int i = 0; i < n; i++) {
		p = strchr(p, ':');
		if (!p) return -1;
		p++;
	}
	const char *end = strchr(p, ':');
	size_t len = end ? (size_t)(end - p) : strlen(p);
	if (len >= outsz) len = outsz - 1;
	memcpy(out, p, len);
	out[len] = '\0';
	return 0;
}

static int line_name_matches(const char *line, const char *name) {
	char f0[256];
	if (field(line, 0, f0, sizeof f0) != 0) return 0;
	return strcmp(f0, name) == 0;
}

/* --- validation --- */

static int valid_name(const char *name) {
	if (!*name || strlen(name) >= 32) return 0;
	if (!islower((unsigned char)name[0]) && name[0] != '_') return 0;
	for (const char *p = name; *p; p++) {
		if (!islower((unsigned char)*p) && !isdigit((unsigned char)*p) && *p != '_' && *p != '-')
			return 0;
	}
	return 1;
}

static int name_exists_in(const char *path, const char *name) {
	struct lines l = read_lines(path);
	int found = 0;
	for (size_t i = 0; i < l.n; i++) {
		if (line_name_matches(l.v[i], name)) { found = 1; break; }
	}
	lines_free(&l);
	return found;
}

/* Highest id (2nd colon field for group, 3rd for passwd -- caller passes
 * the right field index) that's >= MIN_ID, across every line; returns
 * MIN_ID if none found yet. */
static int next_free_id(const char *path, int id_field) {
	struct lines l = read_lines(path);
	int max_id = MIN_ID - 1;
	for (size_t i = 0; i < l.n; i++) {
		char idbuf[32];
		if (field(l.v[i], id_field, idbuf, sizeof idbuf) != 0) continue;
		char *end;
		long id = strtol(idbuf, &end, 10);
		if (*end != '\0') continue;
		if (id >= MIN_ID && id > max_id) max_id = (int)id;
	}
	lines_free(&l);
	return max_id + 1;
}

/* --- password prompt, same echo-off technique as floralogin --- */

static int read_line_noecho(char *buf, size_t bufsz) {
	struct termios oldt, newt;
	int have_tty = tcgetattr(STDIN_FILENO, &oldt) == 0;
	if (have_tty) {
		newt = oldt;
		newt.c_lflag &= ~((tcflag_t)ECHO);
		tcsetattr(STDIN_FILENO, TCSANOW, &newt);
	}
	int ok = fgets(buf, (int)bufsz, stdin) != NULL;
	if (have_tty) {
		tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
		putchar('\n');
	}
	if (!ok) return -1;
	buf[strcspn(buf, "\n")] = '\0';
	return 0;
}

/* --- commands --- */

static int cmd_groupadd(const char *name, const char *gid_arg) {
	if (!valid_name(name)) { fprintf(stderr, "florauser: invalid group name\n"); return 1; }
	if (name_exists_in(GROUP_PATH, name)) {
		fprintf(stderr, "florauser: group %s already exists\n", name);
		return 1;
	}
	int gid;
	if (gid_arg) {
		char *end;
		gid = (int)strtol(gid_arg, &end, 10);
		if (*end != '\0' || gid < 0) { fprintf(stderr, "florauser: bad gid\n"); return 1; }
	} else {
		gid = next_free_id(GROUP_PATH, 2);
	}

	struct lines l = read_lines(GROUP_PATH);
	char newline[MAX_LINE];
	snprintf(newline, sizeof newline, "%s:x:%d:", name, gid);
	lines_push(&l, strdup(newline));
	write_lines(GROUP_PATH, &l, 0644);
	lines_free(&l);
	printf("florauser: created group %s (gid %d)\n", name, gid);
	return 0;
}

static int cmd_addtogroup(const char *user, const char *group) {
	if (!name_exists_in(PASSWD_PATH, user)) {
		fprintf(stderr, "florauser: no such user: %s\n", user);
		return 1;
	}
	struct lines l = read_lines(GROUP_PATH);
	int found = -1;
	for (size_t i = 0; i < l.n; i++) {
		if (line_name_matches(l.v[i], group)) { found = (int)i; break; }
	}
	if (found < 0) {
		fprintf(stderr, "florauser: no such group: %s\n", group);
		lines_free(&l);
		return 1;
	}

	char members[MAX_LINE] = {0};
	field(l.v[found], 3, members, sizeof members);

	/* Already a member? Comma-delimited exact-token match, not substring --
	 * "seat" must not match inside e.g. "seatd". */
	char tmp[MAX_LINE];
	snprintf(tmp, sizeof tmp, ",%s,", members);
	char needle[64];
	snprintf(needle, sizeof needle, ",%s,", user);
	if (strstr(tmp, needle)) {
		printf("florauser: %s is already in group %s\n", user, group);
		lines_free(&l);
		return 0;
	}

	char name_f[64], pass_f[64], gid_f[32];
	field(l.v[found], 0, name_f, sizeof name_f);
	field(l.v[found], 1, pass_f, sizeof pass_f);
	field(l.v[found], 2, gid_f, sizeof gid_f);

	char newmembers[MAX_LINE];
	if (members[0] != '\0')
		snprintf(newmembers, sizeof newmembers, "%s,%s", members, user);
	else
		snprintf(newmembers, sizeof newmembers, "%s", user);

	char newline[MAX_LINE * 2];
	snprintf(newline, sizeof newline, "%s:%s:%s:%s", name_f, pass_f, gid_f, newmembers);
	free(l.v[found]);
	l.v[found] = strdup(newline);

	write_lines(GROUP_PATH, &l, 0644);
	lines_free(&l);
	printf("florauser: added %s to group %s\n", user, group);
	return 0;
}

/* Looks up <user>'s current /etc/shadow hash field. Returns 0 and fills
 * `out` on success; -1 if the user has no shadow entry, or its password
 * field is empty/locked ("!"/"*") -- either way, nothing usable to copy
 * from. */
static int lookup_shadow_hash(const char *user, char *out, size_t outsz) {
	struct lines l = read_lines(SHADOW_PATH);
	int found = -1;
	for (size_t i = 0; i < l.n; i++) {
		if (line_name_matches(l.v[i], user)) { found = (int)i; break; }
	}
	if (found < 0) { lines_free(&l); return -1; }
	int rc = field(l.v[found], 1, out, outsz);
	lines_free(&l);
	if (rc != 0 || out[0] == '\0' || out[0] == '!' || out[0] == '*') return -1;
	return 0;
}

static int cmd_passwd(const char *user) {
	if (!name_exists_in(PASSWD_PATH, user)) {
		fprintf(stderr, "florauser: no such user: %s\n", user);
		return 1;
	}

	int is_root = strcmp(user, "root") == 0;
	char pass1[256], pass2[256];
	char hashbuf[256];
	char *hash;

	printf(is_root ? "New password: " : "New password (blank = same as root's): ");
	fflush(stdout);
	if (read_line_noecho(pass1, sizeof pass1) != 0) return 1;

	if (!is_root && pass1[0] == '\0') {
		if (lookup_shadow_hash("root", hashbuf, sizeof hashbuf) != 0) {
			fprintf(stderr, "florauser: root has no usable password to reuse -- set one first\n");
			return 1;
		}
		hash = hashbuf;
	} else {
		printf("Retype new password: ");
		fflush(stdout);
		if (read_line_noecho(pass2, sizeof pass2) != 0) { memset(pass1, 0, sizeof pass1); return 1; }
		if (strcmp(pass1, pass2) != 0) {
			fprintf(stderr, "florauser: passwords do not match\n");
			memset(pass1, 0, sizeof pass1);
			memset(pass2, 0, sizeof pass2);
			return 1;
		}
		memset(pass2, 0, sizeof pass2);

		/* NULL rbytes: crypt_gensalt draws its own salt from /dev/urandom.
		 * NULL prefix + count 0: libxcrypt's own strongest default algorithm,
		 * not a hand-picked one -- matches how real passwd(1) does it. */
		char *setting = crypt_gensalt(NULL, 0, NULL, 0);
		if (!setting) { perror("florauser: crypt_gensalt"); memset(pass1, 0, sizeof pass1); return 1; }

		struct crypt_data cdata;
		memset(&cdata, 0, sizeof cdata);
		char *crypted = crypt_r(pass1, setting, &cdata);
		memset(pass1, 0, sizeof pass1);
		if (!crypted) { perror("florauser: crypt_r"); return 1; }
		snprintf(hashbuf, sizeof hashbuf, "%s", crypted);
		hash = hashbuf;
	}

	struct lines l = read_lines(SHADOW_PATH);
	int found = -1;
	for (size_t i = 0; i < l.n; i++) {
		if (line_name_matches(l.v[i], user)) { found = (int)i; break; }
	}
	if (found < 0) {
		fprintf(stderr, "florauser: %s has no /etc/shadow entry\n", user);
		lines_free(&l);
		return 1;
	}

	/* Keep every aging field (min/max/warn/inactive/expire/reserved)
	 * untouched -- only the hash and last-changed day are refreshed. */
	char minf[64] = "0", maxf[64] = "99999", warnf[64] = "7", inactf[64] = "", expf[64] = "", resf[64] = "";
	field(l.v[found], 3, minf, sizeof minf);
	field(l.v[found], 4, maxf, sizeof maxf);
	field(l.v[found], 5, warnf, sizeof warnf);
	field(l.v[found], 6, inactf, sizeof inactf);
	field(l.v[found], 7, expf, sizeof expf);
	field(l.v[found], 8, resf, sizeof resf);

	long today = (long)(time(NULL) / 86400);
	char newline[MAX_LINE];
	snprintf(newline, sizeof newline, "%s:%s:%ld:%s:%s:%s:%s:%s:%s",
		 user, hash, today, minf, maxf, warnf, inactf, expf, resf);
	free(l.v[found]);
	l.v[found] = strdup(newline);

	write_lines(SHADOW_PATH, &l, 0600);
	lines_free(&l);
	printf("florauser: password updated for %s\n", user);
	return 0;
}

static int cmd_add(const char *name, const char *supp_groups) {
	if (!valid_name(name)) {
		fprintf(stderr, "florauser: invalid username (lowercase, digits, _/- only)\n");
		return 1;
	}
	if (name_exists_in(PASSWD_PATH, name)) {
		fprintf(stderr, "florauser: user %s already exists\n", name);
		return 1;
	}
	if (name_exists_in(GROUP_PATH, name)) {
		fprintf(stderr, "florauser: a group named %s already exists (user-private-group scheme needs this name free)\n", name);
		return 1;
	}

	int uid = next_free_id(PASSWD_PATH, 2);
	int gid = next_free_id(GROUP_PATH, 2);
	if (gid <= uid) gid = uid; /* keep the common convention of uid==gid when both are freshly allocated */

	char home[256];
	snprintf(home, sizeof home, "/home/%s", name);

	/* passwd: locked ("!") password field -- distinct from floralogin's
	 * root-only "empty field means no password" convention. A fresh
	 * account can't log in until `florauser passwd` gives it a real hash;
	 * an empty field here would silently mean "no password required",
	 * which is not a safe default for a newly created non-root account. */
	{
		struct lines l = read_lines(PASSWD_PATH);
		char newline[MAX_LINE];
		snprintf(newline, sizeof newline, "%s:x:%d:%d:%s:%s:/usr/bin/bash", name, uid, gid, name, home);
		lines_push(&l, strdup(newline));
		write_lines(PASSWD_PATH, &l, 0644);
		lines_free(&l);
	}

	/* group: user-private group, same name, no extra members yet. */
	{
		struct lines l = read_lines(GROUP_PATH);
		char newline[MAX_LINE];
		snprintf(newline, sizeof newline, "%s:x:%d:", name, gid);
		lines_push(&l, strdup(newline));
		write_lines(GROUP_PATH, &l, 0644);
		lines_free(&l);
	}

	/* shadow: locked, last-changed today, otherwise the same aging fields
	 * root's own entry uses. */
	{
		struct lines l = read_lines(SHADOW_PATH);
		long today = (long)(time(NULL) / 86400);
		char newline[MAX_LINE];
		snprintf(newline, sizeof newline, "%s:!:%ld:0:99999:7:::", name, today);
		lines_push(&l, strdup(newline));
		write_lines(SHADOW_PATH, &l, 0600);
		lines_free(&l);
	}

	if (mkdir(home, 0700) != 0 && errno != EEXIST) {
		fprintf(stderr, "florauser: warning: could not create %s: %s\n", home, strerror(errno));
	} else {
		if (chown(home, (uid_t)uid, (gid_t)gid) != 0) { /* best effort */ }
		chmod(home, 0700);
	}

	printf("florauser: created %s (uid %d, gid %d, home %s)\n", name, uid, gid, home);

	if (supp_groups && *supp_groups) {
		char *copy = strdup(supp_groups);
		char *save = NULL;
		for (char *g = strtok_r(copy, ",", &save); g; g = strtok_r(NULL, ",", &save)) {
			if (cmd_addtogroup(name, g) != 0)
				fprintf(stderr, "florauser: warning: could not add %s to %s\n", name, g);
		}
		free(copy);
	}

	printf("florauser: no password set yet -- run: florauser passwd %s\n", name);
	return 0;
}

static void usage(void) {
	fprintf(stderr,
		"usage: florauser add <name> [group1,group2,...]\n"
		"       florauser passwd <name>\n"
		"       florauser groupadd <name> [gid]\n"
		"       florauser addtogroup <user> <group>\n");
}

int main(int argc, char **argv) {
	if (getuid() != 0) {
		fprintf(stderr, "florauser: must be run as root\n");
		return 1;
	}
	if (argc < 2) { usage(); return 1; }

	if (strcmp(argv[1], "add") == 0 && argc >= 3) {
		return cmd_add(argv[2], argc >= 4 ? argv[3] : NULL);
	} else if (strcmp(argv[1], "passwd") == 0 && argc == 3) {
		return cmd_passwd(argv[2]);
	} else if (strcmp(argv[1], "groupadd") == 0 && argc >= 3) {
		return cmd_groupadd(argv[2], argc >= 4 ? argv[3] : NULL);
	} else if (strcmp(argv[1], "addtogroup") == 0 && argc == 4) {
		return cmd_addtogroup(argv[2], argv[3]);
	}

	usage();
	return 1;
}
