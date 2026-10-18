/* zt-blk -- block-layer helper for the UntrashOS loader and the slot initrd
 * (I2: boot from slot files on a stick or on a stock md/LVM/ext4 volume).
 * Static, no libraries; the loader's BusyBox 1.19 has no mdadm, lvm, dmsetup,
 * blkid or a usable losetup.
 *
 *   zt-blk probe DEV                    TYPE= UUID= LABEL= (ext4, vfat, md 1.2 member, LVM2 PV)
 *   zt-blk md-scan                      one line per md 1.2 member:
 *                                       MD dev= uuid= name= level= disks= role= events=
 *   zt-blk md-assemble MD MODE DEV...   assemble /dev/MD (e.g. md120) from the members;
 *                                       MODE = readonly | read-auto | active
 *   zt-blk md-stop MD
 *   zt-blk lvm-scan PV                  one line per LV on a single-PV VG:
 *                                       LV vg= lv= name= uuid= sectors= table=
 *                                       (name/uuid as lvm2 names the dm device, so a
 *                                       later `vgchange -ay` sees the LV as active)
 *   zt-blk dm-create NAME UUID ro|rw TABLE   TABLE = "start len target args[;...]"
 *                                       -> prints /dev/dm-N
 *   zt-blk dm-remove NAME
 *   zt-blk loop-attach FILE ro|rw       -> prints /dev/loopN
 *   zt-blk loop-detach /dev/loopN
 *
 * Only reads metadata; the kernel md driver assembles the array and drops
 * members with stale event counts itself.  LVM: linear (striped, 1 stripe)
 * segments on one PV only, anything else is reported as unsupported. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <linux/dm-ioctl.h>
#include <linux/loop.h>
#include <linux/major.h>
#include <linux/raid/md_u.h>

#ifndef ZB_DIE
static void die(const char *m) { perror(m); exit(1); }
#endif

/* Library use (#define ZT_BLK_LIB, #include "zt-blk.c"): results go to zb_out
 * and the scan callbacks instead of stdout. */
static char zb_out[64];
static void zb_result(const char *s) { snprintf(zb_out, sizeof zb_out, "%s", s); }

static int pread_full(int fd, void *b, size_t n, off_t off)
{
	size_t got = 0;
	while (got < n) {
		ssize_t r = pread(fd, (char *)b + got, n - got, off + got);
		if (r <= 0) return -1;
		got += r;
	}
	return 0;
}

static uint16_t le16(const void *p) { const uint8_t *b = p; return b[0] | b[1] << 8; }
static uint32_t le32(const void *p) { const uint8_t *b = p; return b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24; }
static uint64_t le64(const void *p) { return le32(p) | (uint64_t)le32((const uint8_t *)p + 4) << 32; }

static void hex(char *out, const uint8_t *b, int n)
{
	for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", b[i]);
}

/* Wait up to 5 s for a device node (devtmpfs creates it asynchronously). */
static int wait_node(const char *path, unsigned maj, unsigned min)
{
	for (int i = 0; i < 50; i++) {
		if (access(path, F_OK) == 0) return 0;
		usleep(100000);
	}
	return mknod(path, S_IFBLK | 0600, makedev(maj, min));
}

/* ------------------------------------------------------------------ md 1.2 */

#define MD_SB_MAGIC 0xa92b4efc

struct mdsb {
	char dev[300];
	char uuid[33], name[33];
	int level;
	unsigned disks, role;
	uint64_t events;
};

/* md 1.2: superblock 4 KiB from the start of the member. */
static int md_read(int fd, struct mdsb *s)
{
	uint8_t b[1024];
	if (pread_full(fd, b, sizeof b, 4096) || le32(b) != MD_SB_MAGIC || le32(b + 4) != 1)
		return -1;
	hex(s->uuid, b + 16, 16);
	memcpy(s->name, b + 32, 32); s->name[32] = 0;
	for (char *c = s->name; *c; c++) if (!isgraph((unsigned char)*c)) *c = '_';
	s->level = (int32_t)le32(b + 72);
	s->disks = le32(b + 92);
	s->events = le64(b + 200);
	uint32_t devnr = le32(b + 160), maxdev = le32(b + 220);
	s->role = devnr < maxdev && 256 + 2 * devnr + 2 <= sizeof b ? le16(b + 256 + 2 * devnr) : 0xffff;
	return 0;
}

static int skip_dev(const char *n)
{
	return n[0] == '.' || !strncmp(n, "md", 2) || !strncmp(n, "dm-", 3) || !strncmp(n, "ram", 3) ||
	       !strncmp(n, "zram", 4) || !strncmp(n, "mtdblock", 8) || !strncmp(n, "ubiblock", 8);
}

static void md_print(const struct mdsb *s)
{
	printf("MD dev=%s uuid=%s name=%s level=%d disks=%u role=%u events=%llu\n", s->dev, s->uuid,
	       s->name, s->level, s->disks, s->role, (unsigned long long)s->events);
}

static int md_scan(void (*cb)(const struct mdsb *))
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	if (!d) die("/sys/class/block");
	while ((e = readdir(d))) {
		char p[300];
		struct mdsb s;
		if (skip_dev(e->d_name)) continue;
		snprintf(p, sizeof p, "/dev/%s", e->d_name);
		int fd = open(p, O_RDONLY | O_CLOEXEC);
		if (fd < 0) continue;
		if (md_read(fd, &s) == 0) {
			snprintf(s.dev, sizeof s.dev, "%s", p);
			cb(&s);
		}
		close(fd);
	}
	closedir(d);
	return 0;
}

static int write_sysfs(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	int r = write(fd, val, strlen(val)) == (ssize_t)strlen(val) ? 0 : -1;
	int e = errno;
	close(fd);
	errno = e;
	return r;
}

static int md_assemble(const char *md, const char *mode, char **devs, int n)
{
	char path[64], sys[96];
	unsigned num;
	if (sscanf(md, "md%u", &num) != 1) { fprintf(stderr, "md name must be mdN\n"); return 2; }
	if (strcmp(mode, "readonly") && strcmp(mode, "read-auto") && strcmp(mode, "active")) {
		fprintf(stderr, "mode: readonly | read-auto | active\n"); return 2;
	}
	snprintf(path, sizeof path, "/dev/%s", md);
	/* creates the gendisk (and the devtmpfs node); EEXIST is fine */
	if (write_sysfs("/sys/module/md_mod/parameters/new_array", md) && errno != EEXIST)
		fprintf(stderr, "new_array %s: %s\n", md, strerror(errno));
	if (wait_node(path, MD_MAJOR, num)) die(path);
	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) die(path);
	mdu_array_info_t ai = { .major_version = 1, .minor_version = 2 };	/* raid_disks 0: version only */
	if (ioctl(fd, SET_ARRAY_INFO, &ai)) die("SET_ARRAY_INFO");
	char uuid0[33] = "";
	for (int i = 0; i < n; i++) {
		struct stat st;
		struct mdsb s;
		int dfd = open(devs[i], O_RDONLY | O_CLOEXEC);
		if (dfd < 0 || fstat(dfd, &st) || !S_ISBLK(st.st_mode) || md_read(dfd, &s)) {
			fprintf(stderr, "%s: not an md 1.2 member\n", devs[i]); return 1;
		}
		close(dfd);
		if (!*uuid0) strcpy(uuid0, s.uuid);
		else if (strcmp(uuid0, s.uuid)) { fprintf(stderr, "%s: different array uuid\n", devs[i]); return 1; }
		mdu_disk_info_t di = { .major = major(st.st_rdev), .minor = minor(st.st_rdev) };
		if (ioctl(fd, ADD_NEW_DISK, &di)) die(devs[i]);
	}
	snprintf(sys, sizeof sys, "/sys/block/%s/md/array_state", md);
	if (write_sysfs(sys, mode)) {
		perror("array_state");
		ioctl(fd, STOP_ARRAY, 0);
		return 1;
	}
	close(fd);
	zb_result(path);
	return 0;
}

static int md_stop(const char *md)
{
	char path[64];
	snprintf(path, sizeof path, "/dev/%s", md);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) die(path);
	if (ioctl(fd, STOP_ARRAY, 0)) die("STOP_ARRAY");
	return 0;
}

/* -------------------------------------------------------------------- probe */

struct probe { char type[24], uuid[48], label[40]; };

static int probe_dev(const char *dev, struct probe *r)
{
	uint8_t b[4096];
	int fd = open(dev, O_RDONLY | O_CLOEXEC), ok = -1;
	struct mdsb s;
	memset(r, 0, sizeof *r);
	if (fd < 0) return -1;
	if (md_read(fd, &s) == 0) {
		strcpy(r->type, "linux_raid_member");
		snprintf(r->uuid, sizeof r->uuid, "%s", s.uuid);
		snprintf(r->label, sizeof r->label, "%s", s.name);
		ok = 0;
	} else if (pread_full(fd, b, sizeof b, 0)) {
		ok = -1;
	} else if (le16(b + 1024 + 0x38) == 0xef53) {	/* ext2/3/4 superblock at 1024 */
		const uint8_t *u = b + 1024 + 0x68;
		uint32_t compat_ro = le32(b + 1024 + 0x64), incompat = le32(b + 1024 + 0x60);
		snprintf(r->uuid, sizeof r->uuid,
			 "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
			 u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13],
			 u[14], u[15]);
		strcpy(r->type, incompat & 0x40 /* extents */ || compat_ro & 0x8 ? "ext4" : "ext2");
		snprintf(r->label, sizeof r->label, "%.16s", (char *)b + 1024 + 0x78);
		ok = 0;
	} else {
		/* LVM2 PV: label in one of the first four sectors */
		for (int sct = 0; sct < 4 && ok; sct++)
			if (!memcmp(b + 512 * sct, "LABELONE", 8) && !memcmp(b + 512 * sct + 24, "LVM2 001", 8)) {
				strcpy(r->type, "LVM2_member");
				snprintf(r->uuid, sizeof r->uuid, "%.32s", b + 512 * sct + le32(b + 512 * sct + 20));
				ok = 0;
			}
		/* FAT: boot signature, type string (FAT32 at 0x52, FAT12/16 at 0x36) */
		if (ok && b[510] == 0x55 && b[511] == 0xaa) {
			int off = !memcmp(b + 0x52, "FAT32", 5) ? 0x43 : !memcmp(b + 0x36, "FAT", 3) ? 0x27 : 0;
			if (off) {
				strcpy(r->type, "vfat");
				snprintf(r->uuid, sizeof r->uuid, "%02X%02X-%02X%02X", b[off + 3], b[off + 2],
					 b[off + 1], b[off]);
				snprintf(r->label, sizeof r->label, "%.11s", (char *)b + off + 4);
				ok = 0;
			}
		}
	}
	close(fd);
	return ok;
}

static int probe(const char *dev)
{
	struct probe r;
	if (probe_dev(dev, &r)) return 1;
	printf("TYPE=%s\nUUID=%s\n", r.type, r.uuid);
	if (*r.label) printf("LABEL=%s\n", r.label);
	return 0;
}

/* ---------------------------------------------------------------- LVM2 text */

/* Tiny parser for the LVM2 metadata text: sections "name { ... }", values
 * "key = number | "string" | [ list ]".  Only what lvm-scan needs. */
struct node {
	char key[128];
	char *val;		/* scalar or list text (raw, without quotes for strings) */
	struct node *kids, *next;
};

static const char *tp;

static void skipws(void)
{
	for (;;) {
		while (isspace((unsigned char)*tp)) tp++;
		if (*tp == '#') { while (*tp && *tp != '\n') tp++; continue; }
		return;
	}
}

static struct node *parse_block(void)
{
	struct node *head = NULL, **tail = &head;
	for (;;) {
		skipws();
		if (!*tp || *tp == '}') { if (*tp) tp++; return head; }
		struct node *n = calloc(1, sizeof *n);
		int k = 0;
		while (*tp && (isalnum((unsigned char)*tp) || strchr("_.+-", *tp)) && k < 127) n->key[k++] = *tp++;
		if (!k) { tp++; free(n); continue; }	/* junk: skip one char */
		skipws();
		if (*tp == '{') { tp++; n->kids = parse_block(); }
		else if (*tp == '=') {
			tp++; skipws();
			const char *s = tp;
			if (*tp == '"') {
				s = ++tp;
				while (*tp && *tp != '"') { if (*tp == '\\' && tp[1]) tp++; tp++; }
				n->val = strndup(s, tp - s);
				if (*tp) tp++;
			} else if (*tp == '[') {
				int q = 0;
				while (*tp && (q || *tp != ']')) { if (*tp == '"') q = !q; tp++; }
				if (*tp) tp++;
				n->val = strndup(s, tp - s);
			} else {
				while (*tp && !isspace((unsigned char)*tp) && *tp != '}') tp++;
				n->val = strndup(s, tp - s);
			}
		}
		*tail = n; tail = &n->next;
	}
}

static struct node *child(struct node *n, const char *k)
{
	for (n = n ? n->kids : NULL; n; n = n->next) if (!strcmp(n->key, k)) return n;
	return NULL;
}

static const char *sval(struct node *n, const char *k) { n = child(n, k); return n ? n->val : NULL; }
static long long ival(struct node *n, const char *k) { const char *v = sval(n, k); return v ? atoll(v) : -1; }

static void nodash(char *o, const char *s) { for (; *s; s++) if (*s != '-') *o++ = *s; *o = 0; }

/* lvm2's dm name mangling: '-' inside a VG/LV name is doubled. */
static void mangle(char *o, const char *s) { for (; *s; s++) { *o++ = *s; if (*s == '-') *o++ = '-'; } *o = 0; }

struct lvinfo { const char *vg, *lv, *why; char name[620], uuid[140], table[4096]; long long sectors; };

static void lv_print(const struct lvinfo *l)
{
	if (l->why)
		printf("LV vg=%s lv=%s unsupported=%s\n", l->vg, l->lv, l->why);
	else
		printf("LV vg=%s lv=%s name=%s uuid=%s sectors=%lld table=%s\n", l->vg, l->lv, l->name, l->uuid,
		       l->sectors, l->table);
}

static int lvm_scan(const char *dev, void (*cb)(const struct lvinfo *))
{
	uint8_t b[2048], mh[512];
	int fd = open(dev, O_RDONLY | O_CLOEXEC), lab = -1;
	if (fd < 0) die(dev);
	if (pread_full(fd, b, sizeof b, 0)) die("read label");
	for (int s = 0; s < 4; s++)
		if (!memcmp(b + 512 * s, "LABELONE", 8) && !memcmp(b + 512 * s + 24, "LVM2 001", 8)) { lab = s; break; }
	if (lab < 0) { fprintf(stderr, "%s: no LVM2 label\n", dev); return 1; }
	const uint8_t *pvh = b + 512 * lab + le32(b + 512 * lab + 20);
	char pvid[33];
	memcpy(pvid, pvh, 32); pvid[32] = 0;
	/* disk_locn lists after uuid + device_size: data areas, 0-terminated, then metadata areas */
	const uint8_t *dl = pvh + 40;
	while (le64(dl) || le64(dl + 8)) dl += 16;
	dl += 16;
	uint64_t mda = le64(dl);
	if (!mda) { fprintf(stderr, "%s: PV without metadata area\n", dev); return 1; }
	if (pread_full(fd, mh, sizeof mh, mda) || memcmp(mh + 4, " LVM2 x[5A%r0N*>", 16)) {
		fprintf(stderr, "%s: bad metadata area header\n", dev); return 1;
	}
	uint64_t mstart = le64(mh + 24), msize = le64(mh + 32);
	uint64_t roff = le64(mh + 40), rsize = le64(mh + 48);
	if (!rsize || rsize > msize) { fprintf(stderr, "%s: no metadata text\n", dev); return 1; }
	char *txt = calloc(1, rsize + 1);
	uint64_t first = rsize;
	if (roff + rsize > msize) first = msize - roff;	/* wraps to just after the 512-byte header */
	if (pread_full(fd, txt, first, mstart + roff) ||
	    (first < rsize && pread_full(fd, txt + first, rsize - first, mstart + 512)))
		die("read metadata");
	tp = txt;
	struct node root = { .kids = parse_block() }, *vg = NULL;
	for (struct node *n = root.kids; n; n = n->next) if (n->kids) { vg = n; break; }
	if (!vg) { fprintf(stderr, "%s: no VG in metadata\n", dev); return 1; }
	long long ext = ival(vg, "extent_size");
	struct node *pvs = child(vg, "physical_volumes"), *lvs = child(vg, "logical_volumes"), *pv;
	const char *pvname = NULL;
	long long pe_start = -1;
	int npv = 0;
	for (pv = pvs ? pvs->kids : NULL; pv; pv = pv->next) {
		char id[64];
		npv++;
		nodash(id, sval(pv, "id") ? sval(pv, "id") : "");
		if (!strcmp(id, pvid)) { pvname = pv->key; pe_start = ival(pv, "pe_start"); }
	}
	if (!pvname || ext <= 0 || pe_start < 0) { fprintf(stderr, "%s: PV not in its VG metadata\n", dev); return 1; }
	char vgid[64], vgm[300];
	nodash(vgid, sval(vg, "id") ? sval(vg, "id") : "");
	mangle(vgm, vg->key);
	for (struct node *lv = lvs ? lvs->kids : NULL; lv; lv = lv->next) {
		char lvid[64], lvm[300], table[4096] = "", why[64] = "";
		long long total = 0;
		int segs = 0;
		nodash(lvid, sval(lv, "id") ? sval(lv, "id") : "");
		mangle(lvm, lv->key);
		if (!sval(lv, "status") || !strstr(sval(lv, "status"), "\"VISIBLE\"")) continue;
		for (struct node *sg = lv->kids; sg; sg = sg->next) {
			if (!sg->kids || strncmp(sg->key, "segment", 7)) continue;
			const char *type = sval(sg, "type"), *st = sval(sg, "stripes");
			char pvn[128];
			long long pe;
			if (!type || strcmp(type, "striped") || ival(sg, "stripe_count") != 1 || !st ||
			    sscanf(st, " [ \"%127[^\"]\" , %lld", pvn, &pe) != 2) { strcpy(why, "segment-type"); break; }
			if (strcmp(pvn, pvname)) { strcpy(why, "other-pv"); break; }
			long long s0 = ival(sg, "start_extent") * ext, len = ival(sg, "extent_count") * ext;
			int l = strlen(table);
			snprintf(table + l, sizeof table - l, "%s%lld %lld linear %s %lld", segs ? ";" : "", s0, len,
				 dev, pe_start + pe * ext);
			total += len; segs++;
		}
		if (!*why && !segs) strcpy(why, "no-segments");
		struct lvinfo li = { .vg = vg->key, .lv = lv->key, .why = *why ? why : NULL, .sectors = total };
		snprintf(li.name, sizeof li.name, "%s-%s", vgm, lvm);
		snprintf(li.uuid, sizeof li.uuid, "LVM-%s%s", vgid, lvid);
		snprintf(li.table, sizeof li.table, "%s", table);
		if (npv > 1 && !li.why) li.why = "multi-pv-vg";	/* other PVs may be missing here */
		cb(&li);
	}
	return 0;
}

/* ---------------------------------------------------------------- dm ioctl */

static int dm_ctl(void)
{
	int fd = open("/dev/mapper/control", O_RDWR | O_CLOEXEC);
	if (fd < 0 && errno == ENOENT) {
		mkdir("/dev/mapper", 0755);
		/* misc major 10; minor from /proc/misc */
		FILE *f = fopen("/proc/misc", "r");
		int mi = -1;
		char nm[64];
		int m;
		while (f && fscanf(f, "%d %63s", &m, nm) == 2) if (!strcmp(nm, "device-mapper")) mi = m;
		if (f) fclose(f);
		if (mi >= 0) mknod("/dev/mapper/control", S_IFCHR | 0600, makedev(10, mi));
		fd = open("/dev/mapper/control", O_RDWR | O_CLOEXEC);
	}
	if (fd < 0) die("/dev/mapper/control");
	return fd;
}

static void dm_init(struct dm_ioctl *io, size_t size, const char *name, unsigned flags)
{
	memset(io, 0, size);
	io->version[0] = DM_VERSION_MAJOR; io->version[1] = 0; io->version[2] = 0;
	io->data_size = size;
	io->data_start = sizeof *io;
	io->flags = flags;
	if (name) snprintf(io->name, sizeof io->name, "%s", name);
}

/* block major of device-mapper (dynamic; for mknod without devtmpfs) */
static unsigned dm_major(void)
{
	FILE *f = fopen("/proc/devices", "r");
	char l[128], nm[64];
	unsigned m, r = 253;
	while (f && fgets(l, sizeof l, f))
		if (sscanf(l, "%u %63s", &m, nm) == 2 && !strcmp(nm, "device-mapper")) r = m;
	if (f) fclose(f);
	return r;
}

static int dm_create(const char *name, const char *uuid, const char *mode, const char *table)
{
	static union { struct dm_ioctl io; char buf[16384]; } u;
	int fd = dm_ctl(), ro = !strcmp(mode, "ro");
	dm_init(&u.io, sizeof u, name, 0);
	if (strcmp(uuid, "-")) snprintf(u.io.uuid, sizeof u.io.uuid, "%s", uuid);
	if (ioctl(fd, DM_DEV_CREATE, &u.io)) die("DM_DEV_CREATE");
	unsigned minor_ = minor(u.io.dev);

	dm_init(&u.io, sizeof u, name, ro ? DM_READONLY_FLAG : 0);
	char *p = u.buf + sizeof u.io, *t = strdup(table), *save = NULL;
	for (char *seg = strtok_r(t, ";", &save); seg; seg = strtok_r(NULL, ";", &save)) {
		struct dm_target_spec *ts = (void *)p;
		unsigned long long st, len;
		char ty[DM_MAX_TYPE_NAME];
		int used = 0;
		if (sscanf(seg, " %llu %llu %15s %n", &st, &len, ty, &used) != 3) {
			fprintf(stderr, "bad table line: %s\n", seg); goto fail;
		}
		memset(ts, 0, sizeof *ts);
		ts->sector_start = st; ts->length = len;
		snprintf(ts->target_type, sizeof ts->target_type, "%s", ty);
		char *params = p + sizeof *ts;
		size_t pl = strlen(seg + used) + 1;
		if (params + pl + 8 >= u.buf + sizeof u) { fprintf(stderr, "table too long\n"); goto fail; }
		memcpy(params, seg + used, pl);
		size_t step = (sizeof *ts + pl + 7) & ~7UL;
		ts->next = step;
		p += step;
		u.io.target_count++;
	}
	if (ioctl(fd, DM_TABLE_LOAD, &u.io)) { perror("DM_TABLE_LOAD"); goto fail; }
	dm_init(&u.io, sizeof u, name, 0);
	if (ioctl(fd, DM_DEV_SUSPEND, &u.io)) { perror("DM_DEV_SUSPEND (resume)"); goto fail; }
	char r[32];
	snprintf(r, sizeof r, "/dev/dm-%u", minor_);
	if (wait_node(r, dm_major(), minor_)) die(r);
	zb_result(r);
	return 0;
fail:
	dm_init(&u.io, sizeof u, name, 0);
	ioctl(fd, DM_DEV_REMOVE, &u.io);
	return 1;
}

static int dm_remove(const char *name)
{
	struct dm_ioctl io;
	int fd = dm_ctl();
	dm_init(&io, sizeof io, name, 0);
	if (ioctl(fd, DM_DEV_REMOVE, &io)) die("DM_DEV_REMOVE");
	return 0;
}

/* --------------------------------------------------------------------- loop */

static int loop_attach(const char *file, const char *mode)
{
	int rw = !strcmp(mode, "rw");
	int ff = open(file, (rw ? O_RDWR : O_RDONLY) | O_CLOEXEC);
	if (ff < 0) die(file);
	int ctl = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
	if (ctl < 0) die("/dev/loop-control");
	for (int tries = 0; tries < 8; tries++) {
		int n = ioctl(ctl, LOOP_CTL_GET_FREE);
		char path[32];
		if (n < 0) die("LOOP_CTL_GET_FREE");
		snprintf(path, sizeof path, "/dev/loop%d", n);
		if (wait_node(path, LOOP_MAJOR, n)) die(path);
		int lf = open(path, (rw ? O_RDWR : O_RDONLY) | O_CLOEXEC);
		if (lf < 0) die(path);
		struct loop_config c = { .fd = ff };
		c.info.lo_flags = (rw ? 0 : LO_FLAGS_READ_ONLY);
		snprintf((char *)c.info.lo_file_name, LO_NAME_SIZE, "%s", file);
		if (ioctl(lf, LOOP_CONFIGURE, &c) == 0) { zb_result(path); return 0; }
		if (errno != EBUSY) die("LOOP_CONFIGURE");
		close(lf);	/* raced with another user: next free one */
	}
	fprintf(stderr, "no free loop device\n");
	return 1;
}

static int loop_detach(const char *dev)
{
	int fd = open(dev, O_RDONLY | O_CLOEXEC);
	if (fd < 0 || ioctl(fd, LOOP_CLR_FD, 0)) die(dev);
	return 0;
}

#ifndef ZT_BLK_LIB
static int out(int r) { if (!r && *zb_out) printf("%s\n", zb_out); return r; }

int main(int c, char **v)
{
	const char *cmd = c > 1 ? v[1] : "";
	if (!strcmp(cmd, "probe") && c == 3) return probe(v[2]);
	if (!strcmp(cmd, "md-scan") && c == 2) return md_scan(md_print);
	if (!strcmp(cmd, "md-assemble") && c >= 5) return out(md_assemble(v[2], v[3], v + 4, c - 4));
	if (!strcmp(cmd, "md-stop") && c == 3) return md_stop(v[2]);
	if (!strcmp(cmd, "lvm-scan") && c == 3) return lvm_scan(v[2], lv_print);
	if (!strcmp(cmd, "dm-create") && c == 6) return out(dm_create(v[2], v[3], v[4], v[5]));
	if (!strcmp(cmd, "dm-remove") && c == 3) return dm_remove(v[2]);
	if (!strcmp(cmd, "loop-attach") && c == 4) return out(loop_attach(v[2], v[3]));
	if (!strcmp(cmd, "loop-detach") && c == 3) return loop_detach(v[2]);
	fprintf(stderr, "usage: zt-blk probe DEV | md-scan | md-assemble MD MODE DEV... | md-stop MD |\n"
			"       lvm-scan PV | dm-create NAME UUID ro|rw TABLE | dm-remove NAME |\n"
			"       loop-attach FILE ro|rw | loop-detach DEV\n");
	return 2;
}
#endif
