/* zt-slotinit -- /init of the UntrashOS slot initrd (system from a slot file).
 *
 * The loader (loader/slot/zt-loader) found a slot file (format untrash-slot-2,
 * compact: head + signed trailer), verified manifest, kernel, DTB and this
 * initrd, and started the slot kernel with kexec.  Kernel command line:
 *   untrash.src=vfat:<FSUUID> | ext4:<FSUUID> | md:<MDUUID> | lv:<MDUUID>:<VG>/<LV>
 *                                 container filesystem holding the slot file
 *   untrash.file=/.untrash/slot-a.utslot     path inside the container
 *   untrash.verity=<data blocks>,<root hash>,<salt>   from the signed manifest
 *   untrash.slot=a|b|stick        recorded for untrash-init / untrash-bootstate
 *   init=/usr/lib/untrash/untrash-init
 *
 * Steps: load the modules of /lib/modules/load.list (watchdog first, then
 * feed it: the loader hands over with the 17 s LS1024A watchdog armed), wait
 * for the container (md arrays: all members or 20 s, then degraded), mount it
 * at /run/untrash/host of the new root (ext4 rw, vfat ro), attach the slot
 * file read-only, dm-verity "untrash-root" over it, mount the erofs root,
 * switch_root and exec init.  /run/untrash/boot.env tells untrash-init where
 * the state and swap files live.  Any failure: message on /dev/kmsg and a
 * kernel panic (panic=10 reboots; the loader's boot counter falls back).
 *
 * Test mode (PC, root): ZT_SLOTINIT_TEST=<dir> uses <dir> as the initramfs
 * root, skips modules, watchdog and switch_root, and stops after mounting. */
#define _GNU_SOURCE
#define ZT_BLK_LIB
#define ZB_DIE
#include <signal.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/vfs.h>
#include <time.h>
#include <stdarg.h>

static void say(const char *fmt, ...);
static void die(const char *m);
#include "zt-blk.c"

static const char *T = "";	/* test root prefix */
static int testmode;
static pid_t wdt_pid = -1;

static void say(const char *fmt, ...)
{
	char b[512];
	va_list ap;
	int n = snprintf(b, sizeof b, "UNTRASH-SLOTINIT: ");
	va_start(ap, fmt);
	vsnprintf(b + n, sizeof b - n, fmt, ap);
	va_end(ap);
	int fd = testmode ? 2 : open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd >= 0) {
		size_t l = strlen(b);
		if (l && b[l - 1] != '\n' && l < sizeof b - 1) { b[l++] = '\n'; b[l] = 0; }
		if (write(fd, b, l) < 0) {}
		if (!testmode) close(fd);
	}
}

static void fail(const char *m)
{
	say("FAILED: %s", m);
	if (testmode) exit(1);
	sleep(2);	/* let the blackbox see it */
	/* returning from init panics the kernel; panic=10 reboots */
	exit(1);
}

static void die(const char *m) { char b[256]; snprintf(b, sizeof b, "%s: %s", m, strerror(errno)); fail(b); }

static char cmdline[4096];
static const char *arg(const char *key)	/* value of key=... (static copy) */
{
	static char v[8][1024];
	static int k;
	size_t kl = strlen(key);
	for (char *p = cmdline; (p = strstr(p, key)); p += kl) {
		if ((p != cmdline && p[-1] != ' ') || p[kl] != '=') continue;
		char *e = p + kl + 1, *o = v[k = (k + 1) % 8];
		size_t n = strcspn(e, " \n");
		if (n >= sizeof v[0]) n = sizeof v[0] - 1;
		memcpy(o, e, n); o[n] = 0;
		return o;
	}
	return NULL;
}

static void path(char *o, size_t n, const char *p) { snprintf(o, n, "%s%s", T, p); }

/* ---------------------------------------------------------------- watchdog */

static void wdt_start(void)
{
	int fd = open("/dev/watchdog", O_WRONLY | O_CLOEXEC);
	if (fd < 0) { say("no /dev/watchdog (%s)", strerror(errno)); return; }
	wdt_pid = fork();
	if (wdt_pid == 0) {
		signal(SIGTERM, SIG_DFL);
		for (;;) { if (write(fd, "x", 1) < 0) {} sleep(2); }
	}
	close(fd);
	say("watchdog fed (pid %d)", wdt_pid);
}

/* The child keeps the device open; killing it closes it without the magic
 * 'V', so the watchdog keeps running for untrash-init to take over. */
static void wdt_stop(void)
{
	if (wdt_pid <= 0) return;
	kill(wdt_pid, SIGKILL);
	waitpid(wdt_pid, NULL, 0);
	wdt_pid = -1;
}

/* ----------------------------------------------------------------- modules */

static void load_modules(void)
{
	FILE *f = fopen("/lib/modules/load.list", "r");
	char l[256];
	int n = 0, bad = 0;
	if (!f) { say("no module list"); return; }
	while (fgets(l, sizeof l, f)) {
		l[strcspn(l, "\n")] = 0;
		if (!*l || *l == '#') continue;
		if (!strcmp(l, "@watchdog")) { wdt_start(); continue; }
		int fd = open(l, O_RDONLY | O_CLOEXEC);
		if (fd < 0 || (syscall(SYS_finit_module, fd, "", 0) && errno != EEXIST)) {
			say("module %s: %s", l, strerror(errno)); bad++;
		} else n++;
		if (fd >= 0) close(fd);
	}
	fclose(f);
	say("modules loaded: %d, failed: %d", n, bad);
}

/* --------------------------------------------------------------- container */

static char want_md[40], want_vg[128], want_lv[128];
static char members[16][300];
static int nmembers;
static unsigned want_disks;
static void md_collect(const struct mdsb *s)
{
	if (strcmp(s->uuid, want_md) || nmembers >= 16) return;
	snprintf(members[nmembers++], sizeof members[0], "%s", s->dev);
	want_disks = s->disks;
}

static char lv_dev[64];
static void lv_pick(const struct lvinfo *l)
{
	if (strcmp(l->vg, want_vg) || strcmp(l->lv, want_lv)) return;
	if (l->why) { say("LV %s/%s unsupported (%s)", l->vg, l->lv, l->why); return; }
	if (dm_create(l->name, l->uuid, "rw", l->table)) fail("dm-create LV");
	snprintf(lv_dev, sizeof lv_dev, "%s", zb_out);
}

static int find_fs(const char *type, const char *uuid, char *dev, size_t n)
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	int found = 0;
	if (!d) return 0;
	while (!found && (e = readdir(d))) {
		char p[300];
		struct probe r;
		if (e->d_name[0] == '.' || (!testmode && !strncmp(e->d_name, "loop", 4)) || !strncmp(e->d_name, "ram", 3)) continue;
		snprintf(p, sizeof p, "/dev/%s", e->d_name);
		if (probe_dev(p, &r) == 0 && !strcmp(r.type, type) && !strcasecmp(r.uuid, uuid)) {
			snprintf(dev, n, "%s", p);
			found = 1;
		}
	}
	closedir(d);
	return found;
}

/* -> block device of the container filesystem, or fail */
static void container(const char *src, char *dev, size_t n, char *fstype)
{
	char kind[8] = "", rest[300] = "";
	if (sscanf(src, "%7[^:]:%299s", kind, rest) != 2) fail("bad untrash.src");
	for (int t = 0; t < 600; t++) {		/* 60 s */
		if (!strcmp(kind, "vfat") || !strcmp(kind, "ext4")) {
			strcpy(fstype, kind);
			if (find_fs(kind, rest, dev, n)) return;
		} else if (!strcmp(kind, "md") || !strcmp(kind, "lv")) {
			if (sscanf(rest, "%39[^:]:%127[^/]/%127s", want_md, want_vg, want_lv) < 1) fail("bad untrash.src");
			nmembers = 0;
			md_scan(md_collect);
			/* all members present, or 20 s and at least one (the kernel decides
			 * whether the array can run degraded) */
			if (nmembers && (nmembers >= (int)want_disks || t >= 200)) {
				char *argv[16];
				for (int i = 0; i < nmembers; i++) argv[i] = members[i];
				say("md %s: %d of %u members", want_md, nmembers, want_disks);
				if (md_assemble("md120", "active", argv, nmembers)) fail("md assemble");
				strcpy(fstype, "ext4");
				if (!strcmp(kind, "md")) { snprintf(dev, n, "%s", zb_out); return; }
				char pv[64];
				snprintf(pv, sizeof pv, "%s", zb_out);
				lvm_scan(pv, lv_pick);
				if (!*lv_dev) fail("LV not found on the array");
				snprintf(dev, n, "%s", lv_dev);
				return;
			}
		} else fail("unknown untrash.src kind");
		usleep(100000);
	}
	fail("container not found within 60 s");
}

/* -------------------------------------------------------------- switch_root */

/* Delete the initramfs (rootfs) contents, staying on its filesystem. */
static void rm_tree(int dfd, dev_t rootdev)
{
	DIR *d = fdopendir(dfd);
	struct dirent *e;
	if (!d) { close(dfd); return; }
	while ((e = readdir(d))) {
		struct stat st;
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
		if (fstatat(dfd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) || st.st_dev != rootdev) continue;
		if (S_ISDIR(st.st_mode)) {
			int sub = openat(dfd, e->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
			if (sub >= 0) rm_tree(sub, rootdev);
			unlinkat(dfd, e->d_name, AT_REMOVEDIR);
		} else unlinkat(dfd, e->d_name, 0);
	}
	closedir(d);
}

int main(int argc, char **argv)
{
	char p[512], dev[300], fstype[8], host[300], nr[300];
	(void)argc;
	if (getenv("ZT_SLOTINIT_TEST")) { T = getenv("ZT_SLOTINIT_TEST"); testmode = 1; }
	if (!testmode) {
		mount("proc", "/proc", "proc", 0, NULL);
		mount("sysfs", "/sys", "sysfs", 0, NULL);
		mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	}
	path(p, sizeof p, "/proc/cmdline");
	FILE *f = fopen(testmode && getenv("ZT_SLOTINIT_CMDLINE") ? getenv("ZT_SLOTINIT_CMDLINE") : "/proc/cmdline", "r");
	if (!f || !fgets(cmdline, sizeof cmdline, f)) fail("no /proc/cmdline");
	fclose(f);
	say("start");
	/* USB blackbox (nas-tools/zt-blackbox, ZTBLACKBOX1 stick): the whole
	 * kernel log from second 0 synchronously on the stick, so a reset or a
	 * panic in this stage stays readable.  '@' in argv[0]: systemd-shutdown
	 * spares it; it survives switch_root (open fds). */
	if (!testmode && access("/bin/zt-blackbox", X_OK) == 0) {
		pid_t bb = fork();
		if (bb == 0) {
			char *a[] = { "@zt-blackbox", "20", NULL };
			int nul = open("/dev/null", O_RDWR);
			if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); dup2(nul, 2); }
			execv("/bin/zt-blackbox", a);
			_exit(127);
		}
		say("blackbox started (pid %d)", bb);
	}
	if (!testmode) load_modules();

	const char *src = arg("untrash.src"), *file = arg("untrash.file"), *ver = arg("untrash.verity");
	const char *slot = arg("untrash.slot"), *init = arg("init");
	if (!src || !file || !ver) fail("untrash.src/file/verity missing on the command line");
	if (!slot) slot = "?";
	if (!init) init = "/sbin/init";
	unsigned long long nblk;
	char rh[129], salt[129];
	if (sscanf(ver, "%llu,%128[0-9a-f],%128[0-9a-f-]", &nblk, rh, salt) != 3) fail("bad untrash.verity");

	container(src, dev, sizeof dev, fstype);
	/* MS_MOVE refuses mounts below a shared parent (PC test; rootfs is private) */
	mount(NULL, *T ? T : "/", NULL, MS_REC | MS_PRIVATE, NULL);
	path(host, sizeof host, "/host");
	mkdir(host, 0755);
	int rw = !strcmp(fstype, "ext4");
	if (mount(dev, host, fstype, rw ? MS_NOATIME : MS_RDONLY, NULL)) die("mount container");
	say("container %s (%s, %s) mounted", dev, fstype, rw ? "rw" : "ro");

	char sf[700];
	snprintf(sf, sizeof sf, "%s%s", host, file);
	struct stat st;
	if (stat(sf, &st) || st.st_size < (off_t)((nblk + 2) * 4096)) fail("slot file missing or too small");
	if (loop_attach(sf, "ro")) fail("loop");
	char loopdev[64], table[1024];
	snprintf(loopdev, sizeof loopdev, "%s", zb_out);
	snprintf(table, sizeof table, "0 %llu verity 1 %s %s 4096 4096 %llu %llu sha256 %s %s",
		 nblk * 8, loopdev, loopdev, nblk, nblk, rh, salt);
	if (dm_create("untrash-root", "-", "ro", table)) fail("verity");
	char rootdev[64];
	snprintf(rootdev, sizeof rootdev, "%s", zb_out);
	path(nr, sizeof nr, "/newroot");
	mkdir(nr, 0755);
	if (mount(rootdev, nr, "erofs", MS_RDONLY, NULL)) die("mount erofs root");
	say("root %s on %s (verity %.16s) mounted", rootdev, loopdev, rh);

	/* /run of the new root: a tmpfs (systemd keeps an existing one) with the
	 * container under /run/untrash/host */
	snprintf(p, sizeof p, "%s/run", nr);
	if (mount("tmpfs", p, "tmpfs", MS_NOSUID | MS_NODEV, "mode=755")) die("tmpfs /run");
	snprintf(p, sizeof p, "%s/run/untrash", nr); mkdir(p, 0755);
	snprintf(p, sizeof p, "%s/run/untrash/host", nr); mkdir(p, 0755);
	if (mount(host, p, NULL, MS_MOVE, NULL)) die("move container mount");
	snprintf(p, sizeof p, "%s/run/untrash/boot.env", nr);
	f = fopen(p, "w");
	if (!f) die("boot.env");
	fprintf(f, "ZT_BOOT=file\nZT_SLOT=%s\nZT_SRC=%s\nZT_FILE=%s\nZT_HOST=/run/untrash/host\n"
		   "ZT_HOST_DEV=%s\nZT_HOST_FS=%s\nZT_HOST_RW=%d\n", slot, src, file, dev, fstype, rw);
	fclose(f);
	if (testmode) { say("TEST: stop before switch_root"); return 0; }

	for (const char *m = "/dev\0/proc\0/sys\0"; *m; m += strlen(m) + 1) {
		snprintf(p, sizeof p, "%s%s", nr, m);
		if (mount(m, p, NULL, MS_MOVE, NULL)) say("move %s: %s", m, strerror(errno));
	}
	wdt_stop();
	say("switch_root -> %s", init);
	if (chdir(nr)) die("chdir");
	struct stat rs;
	stat("/", &rs);
	rm_tree(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), rs.st_dev);
	if (mount(".", "/", NULL, MS_MOVE, NULL)) die("move root");
	if (chroot(".") || chdir("/")) die("chroot");
	argv[0] = (char *)init;
	execv(init, argv);
	die("exec init");
	return 1;
}
