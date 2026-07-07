/* fauelf -- rewrites absolute-path DT_NEEDED entries in an ELF64 file to their bare basename, in place. See fauelf.md. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

typedef struct {
	unsigned char e_ident[16];
	uint16_t e_type;
	uint16_t e_machine;
	uint32_t e_version;
	uint64_t e_entry;
	uint64_t e_phoff;
	uint64_t e_shoff;
	uint32_t e_flags;
	uint16_t e_ehsize;
	uint16_t e_phentsize;
	uint16_t e_phnum;
	uint16_t e_shentsize;
	uint16_t e_shnum;
	uint16_t e_shstrndx;
} Elf64_Ehdr_min;

typedef struct {
	uint32_t p_type;
	uint32_t p_flags;
	uint64_t p_offset;
	uint64_t p_vaddr;
	uint64_t p_paddr;
	uint64_t p_filesz;
	uint64_t p_memsz;
	uint64_t p_align;
} Elf64_Phdr_min;

typedef struct {
	int64_t d_tag;
	uint64_t d_val;
} Elf64_Dyn_min;

#define PT_LOAD    1
#define PT_DYNAMIC 2
#define DT_NULL    0
#define DT_NEEDED  1
#define DT_STRTAB  5

static const char *g_path;

static void skip(void) { exit(0); }

static void die(const char *msg) {
	fprintf(stderr, "fauelf: %s: %s\n", g_path, msg);
	exit(1);
}

static uint64_t vaddr_to_offset(Elf64_Phdr_min *phdrs, int phnum, uint64_t vaddr) {
	int i;
	for (i = 0; i < phnum; i++) {
		if (phdrs[i].p_type != PT_LOAD) continue;
		if (vaddr >= phdrs[i].p_vaddr && vaddr < phdrs[i].p_vaddr + phdrs[i].p_filesz)
			return phdrs[i].p_offset + (vaddr - phdrs[i].p_vaddr);
	}
	die("DT_STRTAB address not covered by any PT_LOAD segment");
	return 0; /* unreached */
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: fauelf <file>\n");
		return 1;
	}
	g_path = argv[1];

	struct stat st;
	if (stat(g_path, &st) != 0 || !S_ISREG(st.st_mode)) skip();
	if (st.st_size < (off_t)sizeof(Elf64_Ehdr_min)) skip();

	int fd = open(g_path, O_RDWR);
	if (fd < 0) skip();

	Elf64_Ehdr_min eh;
	if (pread(fd, &eh, sizeof(eh), 0) != (ssize_t)sizeof(eh)) skip();
	if (memcmp(eh.e_ident, "\x7f""ELF", 4) != 0) skip();
	if (eh.e_ident[4] != 2) skip(); /* ELFCLASS64 only */
	if (eh.e_phnum == 0) skip();

	size_t ph_bytes = (size_t)eh.e_phnum * sizeof(Elf64_Phdr_min);
	Elf64_Phdr_min *phdrs = malloc(ph_bytes);
	if (!phdrs) die("out of memory reading program headers");
	if (pread(fd, phdrs, ph_bytes, (off_t)eh.e_phoff) != (ssize_t)ph_bytes)
		die("truncated program header table");

	Elf64_Phdr_min *dynseg = NULL;
	int i;
	for (i = 0; i < eh.e_phnum; i++) {
		if (phdrs[i].p_type == PT_DYNAMIC) { dynseg = &phdrs[i]; break; }
	}
	if (!dynseg) { free(phdrs); skip(); }

	int ndyn = (int)(dynseg->p_filesz / sizeof(Elf64_Dyn_min));
	Elf64_Dyn_min *dyns = malloc(dynseg->p_filesz);
	if (!dyns) die("out of memory reading dynamic section");
	if (pread(fd, dyns, dynseg->p_filesz, (off_t)dynseg->p_offset) != (ssize_t)dynseg->p_filesz)
		die("truncated dynamic section");

	uint64_t strtab_vaddr = 0;
	int have_strtab = 0;
	for (i = 0; i < ndyn && dyns[i].d_tag != DT_NULL; i++) {
		if (dyns[i].d_tag == DT_STRTAB) { strtab_vaddr = dyns[i].d_val; have_strtab = 1; break; }
	}
	if (!have_strtab) die("no DT_STRTAB entry in a file with a dynamic section");
	uint64_t strtab_off = vaddr_to_offset(phdrs, eh.e_phnum, strtab_vaddr);

	int patched = 0;
	for (i = 0; i < ndyn && dyns[i].d_tag != DT_NULL; i++) {
		if (dyns[i].d_tag != DT_NEEDED) continue;

		char buf[4096]; /* generous headroom, not a hard format limit */
		ssize_t n = pread(fd, buf, sizeof(buf) - 1, (off_t)(strtab_off + dyns[i].d_val));
		if (n <= 0) die("couldn't read a DT_NEEDED string from .dynstr");
		buf[n] = '\0';
		size_t orig_len = strnlen(buf, (size_t)n);
		if (orig_len == 0 || buf[0] != '/') continue; /* already a bare soname */

		const char *slash = strrchr(buf, '/');
		const char *base = slash ? slash + 1 : buf;
		size_t base_len = strlen(base);
		if (base_len == 0 || base_len >= orig_len) continue; /* nothing to shrink */

		off_t str_pos = (off_t)(strtab_off + dyns[i].d_val);
		if (pwrite(fd, base, base_len, str_pos) != (ssize_t)base_len)
			die("failed writing rewritten NEEDED string");
		char zeros[256] = {0};
		size_t pad = orig_len - base_len;
		off_t pad_pos = str_pos + (off_t)base_len;
		while (pad > 0) {
			size_t chunk = pad < sizeof(zeros) ? pad : sizeof(zeros);
			if (pwrite(fd, zeros, chunk, pad_pos) != (ssize_t)chunk)
				die("failed padding rewritten NEEDED string");
			pad_pos += (off_t)chunk;
			pad -= chunk;
		}

		printf("fauelf: %s: NEEDED \"%s\" -> \"%s\"\n", g_path, buf, base);
		patched++;
	}

	free(dyns);
	free(phdrs);
	close(fd);
	(void)patched;
	return 0;
}
