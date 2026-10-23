/*
 * ztpk - helper for the UntrashOS PartnerKey script (usb_key_func.sh) under
 * the stock NAS542 firmware (BusyBox 1.19, no Python).  Built static for ARM
 * by install/mk-partnerkey.sh; install/test-ztpk.sh checks that it
 * gives the same bytes as the reference install/envfs.py.
 *
 *   ztpk env-check ENV.bin            Barebox envfs CRCs -> "OK files=N"
 *   ztpk env-get ENV.bin VAR          last VAR= in /config (quotes removed)
 *   ztpk env-untrash ENV.bin OUT.bin  stock env -> UntrashOS env, prints
 *                                     "OK slot=X" (X = kernel slot for the
 *                                     loader); "REFUSED <why>", exit 3
 *   ztpk uimage-check FILE            legacy uImage header + data CRC ->
 *                                     "OK size=N name=<name>"
 *   ztpk crc32 FILE                   zlib CRC-32 (tests)
 *
 * The env transformation is documented in envfs.py untrash().
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define ENV_MAGIC 0x798fba79u
#define INODE_MAGIC 0x67a8c78du
#define MAXF 64

static uint32_t crc_tab[256];
static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_tab[i] = c;
	}
}
static uint32_t crc32(const unsigned char *p, size_t n)
{
	uint32_t c = 0xffffffffu;
	while (n--)
		c = crc_tab[(c ^ *p++) & 0xff] ^ (c >> 8);
	return c ^ 0xffffffffu;
}
static uint32_t le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void put_le32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static size_t pad4(size_t n) { return (n + 3) & ~(size_t)3; }

static unsigned char *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(2); }
	size_t cap = 1 << 16, n = 0, r;
	unsigned char *b = malloc(cap);
	while ((r = fread(b + n, 1, cap - n, f)) > 0) {
		n += r;
		if (n == cap) b = realloc(b, cap *= 2);
	}
	fclose(f);
	*len = n;
	return b;
}

struct file { char name[256]; unsigned char *data; size_t len; };
struct env { uint32_t prio, flags; size_t part; int n; struct file f[MAXF]; };

static int env_parse(const unsigned char *b, size_t len, struct env *e, const char **why)
{
	if (len < 28 || le32(b) != ENV_MAGIC) { *why = "no envfs superblock"; return -1; }
	if (crc32(b, 24) != le32(b + 24)) { *why = "superblock crc mismatch"; return -1; }
	uint32_t size = le32(b + 12);
	if (28 + (size_t)size > len) { *why = "data size beyond partition"; return -1; }
	const unsigned char *d = b + 28;
	if (crc32(d, size) != le32(b + 8)) { *why = "data crc mismatch"; return -1; }
	e->prio = le32(b + 4); e->flags = le32(b + 16); e->part = len; e->n = 0;
	size_t off = 0;
	while (off < size) {
		if (off + 12 > size || le32(d + off) != INODE_MAGIC) { *why = "bad inode"; return -1; }
		uint32_t fsize = le32(d + off + 4), hlen = le32(d + off + 8);
		size_t doff = off + 12 + pad4(hlen);
		if (doff + fsize > size || hlen >= sizeof e->f[0].name || e->n == MAXF) { *why = "bad inode size"; return -1; }
		struct file *f = &e->f[e->n++];
		memcpy(f->name, d + off + 12, hlen); f->name[hlen] = 0;
		f->data = malloc(fsize + 1); memcpy(f->data, d + doff, fsize); f->len = fsize;
		off = doff + pad4(fsize);
	}
	return 0;
}

static unsigned char *env_pack(const struct env *e)
{
	size_t n = 0;
	for (int i = 0; i < e->n; i++)
		n += 12 + pad4(strlen(e->f[i].name) + 1) + pad4(e->f[i].len);
	if (28 + n > e->part) return NULL;
	unsigned char *b = malloc(e->part);
	memset(b, 0xff, e->part);
	unsigned char *d = b + 28;
	memset(d, 0, n);
	size_t off = 0;
	for (int i = 0; i < e->n; i++) {
		size_t hl = strlen(e->f[i].name) + 1;
		put_le32(d + off, INODE_MAGIC); put_le32(d + off + 4, e->f[i].len); put_le32(d + off + 8, hl);
		memcpy(d + off + 12, e->f[i].name, hl);
		off += 12 + pad4(hl);
		memcpy(d + off, e->f[i].data, e->f[i].len);
		off += pad4(e->f[i].len);
	}
	put_le32(b, ENV_MAGIC); put_le32(b + 4, e->prio); put_le32(b + 8, crc32(d, n));
	put_le32(b + 12, n); put_le32(b + 16, e->flags); put_le32(b + 20, 0);
	put_le32(b + 24, crc32(b, 24));
	return b;
}

static struct file *find(struct env *e, const char *name)
{
	for (int i = 0; i < e->n; i++)
		if (!strcmp(e->f[i].name, name)) return &e->f[i];
	return NULL;
}

/* last NAME=VALUE line of the config; quotes removed; NULL if absent */
static char *config_var(struct file *cfg, const char *name, char *out, size_t outsz)
{
	size_t nl = strlen(name);
	int found = 0;
	const char *p = (const char *)cfg->data, *end = p + cfg->len;
	while (p < end) {
		const char *eol = memchr(p, '\n', end - p);
		if (!eol) eol = end;
		if ((size_t)(eol - p) > nl && !memcmp(p, name, nl) && p[nl] == '=') {
			const char *v = p + nl + 1, *ve = eol;
			while (v < ve && (*v == ' ' || *v == '\t' || *v == '\r')) v++;
			while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t' || ve[-1] == '\r')) ve--;
			if (ve - v >= 2 && *v == '"' && ve[-1] == '"') { v++; ve--; }
			size_t l = ve - v < (long)outsz - 1 ? (size_t)(ve - v) : outsz - 1;
			memcpy(out, v, l); out[l] = 0; found = 1;
		}
		p = eol + 1;
	}
	return found ? out : NULL;
}

/* lines of a file: offsets of line starts; the text after the last '\n' is
 * one more line (possibly empty), as with Python str.split('\n') */
static int split_lines(struct file *f, size_t *st, size_t *ln, int max)
{
	int n = 0;
	size_t s = 0;
	for (size_t i = 0; i <= f->len; i++) {
		if (i == f->len || f->data[i] == '\n') {
			if (n == max) return -1;
			st[n] = s; ln[n] = i - s; n++; s = i + 1;
		}
	}
	return n;
}
static int line_is(struct file *f, size_t st, size_t ln, const char *s)
{
	return ln == strlen(s) && !memcmp(f->data + st, s, ln);
}
static int line_has(struct file *f, size_t st, size_t ln, const char *s)
{
	size_t k = strlen(s);
	for (size_t i = 0; i + k <= ln; i++)
		if (!memcmp(f->data + st + i, s, k)) return 1;
	return 0;
}
/* replace lines [a, a+cnt) of f by the text rep (no trailing '\n') */
static void replace_lines(struct file *f, size_t *st, size_t *ln, int a, int cnt, const char *rep)
{
	size_t from = st[a], to = st[a + cnt - 1] + ln[a + cnt - 1];
	size_t rl = strlen(rep), nl = f->len - (to - from) + rl;
	unsigned char *nd = malloc(nl + 1);
	memcpy(nd, f->data, from);
	memcpy(nd + from, rep, rl);
	memcpy(nd + from + rl, f->data + to, f->len - to);
	free(f->data); f->data = nd; f->len = nl;
}

static const char LOADER[] =
	"#!/bin/sh\n"
	"# UntrashOS: start the loader in NAND kernel%c.  The stock boot follows\n"
	"# when this returns: after the loader asked for the way back to stock (16-byte\n"
	"# mark in RAM at 0x2e000000, os/loader/zt-loader) or when bootm fails.\n"
	"echo\n"
	"mw 0x2e000010 0x5a54726f\n"
	"mw 0x2e000014 0x6c6c6261\n"
	"mw 0x2e000018 0x636b2d31\n"
	"mw 0x2e00001c 0x8f1e2d3c\n"
	"if memcmp 0x2e000000 0x2e000010 16; then\n"
	"\techo \"UntrashOS: way back to stock requested, stock boot\"\n"
	"else\n"
	"\techo \"UntrashOS: loader from NAND kernel%c\"\n"
	"\tmw 0x904700D0 0x010000A0\n"
	"\tmw 0x90470058 0x05000000\n"
	"\tmw 0x90458000 0x80000001\n"
	"\tmw 0x90458028 0x80001388\n"
	"\tmw 0x9045802C 0x00000fa0\n"
	"\t# the loader kernel uses its built-in command line (CMDLINE_FORCE)\n"
	"\tbootargs=\"console=ttyS0,115200n8\"\n"
	"\tbootm /dev/nand0.kernel%c.bb\n"
	"\techo \"UntrashOS: loader bootm returned, stock boot\"\n"
	"fi\n";

#define MAXL 4096
static size_t st[MAXL], ln[MAXL];

static int untrash(struct env *e, char *slot, const char **why)
{
	struct file *cfg = find(e, "/config"), *init = find(e, "/bin/init");
	if (!cfg || !init || !find(e, "/bin/boot")) { *why = "not a NAS542 stock env (/config, /bin/init or /bin/boot missing)"; return -1; }
	if (find(e, "/bin/untrash_loader") || find(e, "/bin/boot_zyxeluntrash_loader")) { *why = "env already starts an UntrashOS loader"; return -1; }
	char cur[16], nxt[16];
	if (!config_var(cfg, "curr_bootfrom", cur, sizeof cur) || !config_var(cfg, "next_bootfrom", nxt, sizeof nxt) ||
	    (strcmp(cur, "1") && strcmp(cur, "2")) || strcmp(cur, nxt)) { *why = "no settled stock slot (curr_bootfrom/next_bootfrom)"; return -1; }
	*slot = cur[0] == '1' ? '2' : '1';

	int n = split_lines(init, st, ln, MAXL), last = -1;
	if (n < 0) { *why = "init too long"; return -1; }
	for (int i = 0; i < n; i++)
		for (size_t k = 0; k < ln[i]; k++)
			if (init->data[st[i] + k] != ' ' && init->data[st[i] + k] != '\t' && init->data[st[i] + k] != '\r') { last = i; break; }
	struct file *bz = find(e, "/bin/boot_zyxeluntrash");
	if (last >= 0 && line_is(init, st[last], ln[last], "boot")) {
		replace_lines(init, st, ln, last, 1, "/env/bin/untrash_loader\nboot");
	} else if (bz && memmem(init->data, init->len, "\t/env/bin/boot_zyxeluntrash\n", 28)) {
		int m = split_lines(bz, st, ln, MAXL), hit[2], h = 0;
		if (m < 0) { *why = "boot_zyxeluntrash too long"; return -1; }
		for (int i = 1; i < m; i++)
			if (line_is(bz, st[i], ln[i], "    /env/bin/boot_zyxeluntrash_recovery") &&
			    line_has(bz, st[i - 1], ln[i - 1], "echo") && line_has(bz, st[i - 1], ln[i - 1], "TFTP")) {
				if (h == 2) { h = 3; break; }
				hit[h++] = i;
			}
		if (h != 2) { *why = "dev env: expected 2 TFTP fallbacks in boot_zyxeluntrash"; return -1; }
		/* later line first, so the earlier offsets stay valid */
		replace_lines(bz, st, ln, hit[1], 1, "    /env/bin/untrash_loader");
		replace_lines(bz, st, ln, hit[0], 1, "    /env/bin/untrash_loader");
	} else {
		*why = "unknown env: /bin/init does not end with the stock \"boot\""; return -1;
	}
	if (e->n == MAXF) { *why = "too many files"; return -1; }
	struct file *f = &e->f[e->n++];
	strcpy(f->name, "/bin/untrash_loader");
	f->data = malloc(sizeof LOADER + 8);
	f->len = sprintf((char *)f->data, LOADER, *slot, *slot, *slot);
	return 0;
}

int main(int argc, char **argv)
{
	crc_init();
	size_t len;
	const char *why = "";
	struct env *e = calloc(1, sizeof *e);
	if (argc == 3 && !strcmp(argv[1], "crc32")) {
		unsigned char *b = slurp(argv[2], &len);
		printf("%08x\n", crc32(b, len));
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "uimage-check")) {
		unsigned char *b = slurp(argv[2], &len), h[64];
		if (len < 64 || be32(b) != 0x27051956u) { puts("BAD no uImage header"); return 1; }
		memcpy(h, b, 64); memset(h + 4, 0, 4);
		if (crc32(h, 64) != be32(b + 4)) { puts("BAD header crc"); return 1; }
		uint32_t size = be32(b + 12);
		if (64 + (size_t)size > len) { puts("BAD truncated"); return 1; }
		if (crc32(b + 64, size) != be32(b + 24)) { puts("BAD data crc"); return 1; }
		char name[33];
		memcpy(name, b + 32, 32); name[32] = 0;
		printf("OK size=%u os=%u arch=%u type=%u name=%s\n", 64 + size, b[28], b[29], b[30], name);
		return 0;
	}
	if (argc >= 3 && (!strcmp(argv[1], "env-check") || !strcmp(argv[1], "env-get") || !strcmp(argv[1], "env-untrash"))) {
		unsigned char *b = slurp(argv[2], &len);
		if (env_parse(b, len, e, &why)) { printf("BAD %s\n", why); return 1; }
		if (!strcmp(argv[1], "env-check") && argc == 3) {
			printf("OK files=%d\n", e->n);
			return 0;
		}
		if (!strcmp(argv[1], "env-get") && argc == 4) {
			char v[256];
			struct file *cfg = find(e, "/config");
			if (!cfg || !config_var(cfg, argv[3], v, sizeof v)) return 1;
			puts(v);
			return 0;
		}
		if (!strcmp(argv[1], "env-untrash") && argc == 4) {
			char slot;
			if (untrash(e, &slot, &why)) { printf("REFUSED %s\n", why); return 3; }
			unsigned char *o = env_pack(e);
			if (!o) { puts("REFUSED new env does not fit the partition"); return 3; }
			FILE *f = fopen(argv[3], "wb");
			if (!f || fwrite(o, 1, e->part, f) != e->part || fclose(f)) { perror(argv[3]); return 2; }
			printf("OK slot=%c\n", slot);
			return 0;
		}
	}
	fprintf(stderr, "usage: ztpk env-check|env-get|env-untrash|uimage-check|crc32 ...\n");
	return 2;
}
