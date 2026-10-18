/* zt-blackbox -- UART-free boot log: copy /dev/kmsg synchronously to a raw
 * USB stick so that a hang (e.g. in a network driver probe) leaves a readable
 * log behind.  No filesystem is involved; the stick is prepared on the PC with
 * tools/zt-blackbox-host.sh.
 *
 * Stick layout (raw block device):
 *   0x000000  header: "ZTBLACKBOX1\0" (12 bytes), u32 LE boot counter at 16
 *   0x100000  slot 0 .. slot 15, 1 MiB each, slot = counter % 16
 * A slot is plain text, NUL-padded; the first line is "ZTBB boot=<n>".
 *
 *   zt-blackbox [WAIT_SECONDS]   find the stick (default wait 15 s), log until
 *                                the slot is full; marks lines written by rc
 *                                via /dev/kmsg like every other record.
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAGIC		"ZTBLACKBOX1"
#define SLOT_BASE	0x100000UL
#define SLOT_SIZE	0x100000UL
#define NSLOTS		16
#define FLUSH_MS	200

static void kmsg(const char *s)
{
	int fd = open("/dev/kmsg", O_WRONLY);

	if (fd >= 0) {
		write(fd, s, strlen(s));
		close(fd);
	}
}

static int find_stick(char *path, size_t len)
{
	const char *pat = getenv("ZT_BB_DEV");	/* test hook: explicit device/file */
	glob_t g;
	size_t i;
	int fd = -1;

	if (glob(pat ? pat : "/dev/sd[a-z]", 0, NULL, &g))
		return -1;
	for (i = 0; i < g.gl_pathc && fd < 0; i++) {
		char hdr[16];
		int f = open(g.gl_pathv[i], O_RDWR | O_SYNC);

		if (f < 0)
			continue;
		if (pread(f, hdr, sizeof(hdr), 0) == sizeof(hdr) &&
		    !memcmp(hdr, MAGIC, sizeof(MAGIC))) {
			snprintf(path, len, "%s", g.gl_pathv[i]);
			fd = f;
		} else {
			close(f);
		}
	}
	globfree(&g);
	return fd;
}

/* "pri,seq,usec,flags;text\n" (+ " KEY=val" continuation lines) -> "[s.us] text\n" */
static size_t format(const char *rec, ssize_t n, char *out, size_t cap)
{
	unsigned long long usec = 0;
	const char *p = memchr(rec, ';', n), *end;
	size_t len;

	if (!p)
		return 0;
	sscanf(rec, "%*u,%*u,%llu", &usec);
	p++;
	end = memchr(p, '\n', rec + n - p);
	len = end ? (size_t)(end - p) : (size_t)(rec + n - p);
	return snprintf(out, cap, "[%5llu.%06llu] %.*s\n",
			usec / 1000000, usec % 1000000, (int)len, p);
}

int main(int argc, char **argv)
{
	int wait = argc > 1 ? atoi(argv[1]) : 15;
	char dev[64], rec[8192], line[8300], msg[128];
	static char zero[SLOT_SIZE];
	unsigned char hdr[20];
	uint32_t boot;
	off_t base, off = 0;
	int fd = -1, k, t;

	for (t = 0; t <= wait * 2 && fd < 0; t++) {
		fd = find_stick(dev, sizeof(dev));
		if (fd < 0)
			usleep(500000);
	}
	if (fd < 0) {
		kmsg("ZT-BB:NO_STICK\n");
		return 1;
	}
	if (pread(fd, hdr, sizeof(hdr), 0) != sizeof(hdr))
		return 1;
	boot = (hdr[16] | hdr[17] << 8 | hdr[18] << 16 | (uint32_t)hdr[19] << 24) + 1;
	hdr[16] = boot; hdr[17] = boot >> 8; hdr[18] = boot >> 16; hdr[19] = boot >> 24;
	if (pwrite(fd, hdr + 16, 4, 16) != 4)
		return 1;
	base = SLOT_BASE + (off_t)(boot % NSLOTS) * SLOT_SIZE;
	if (pwrite(fd, zero, SLOT_SIZE, base) != (ssize_t)SLOT_SIZE)
		return 1;
	off = snprintf(line, sizeof(line), "ZTBB boot=%u dev=%s\n", boot, dev);
	pwrite(fd, line, off, base);
	snprintf(msg, sizeof(msg), "ZT-BB:LOGGING %s boot=%u slot=%u\n", dev, boot, boot % NSLOTS);
	kmsg(msg);

	k = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);	/* starts at the oldest record */
	if (k < 0)
		return 1;
	for (;;) {
		struct pollfd pfd = { .fd = k, .events = POLLIN };
		char buf[16384];
		size_t used = 0;
		ssize_t n;

		poll(&pfd, 1, -1);
		usleep(FLUSH_MS * 1000);	/* batch records, then one synchronous write */
		do {
			size_t l = 0;

			n = read(k, rec, sizeof(rec));
			if (n > 0)
				l = format(rec, n, line, sizeof(line));
			if (used && (n <= 0 || used + l > sizeof(buf))) {
				if (off + used >= SLOT_SIZE - 64) {
					pwrite(fd, "ZTBB slot full\n", 15, base + off);
					return 0;
				}
				if (pwrite(fd, buf, used, base + off) == (ssize_t)used)
					off += used;
				used = 0;
			}
			memcpy(buf + used, line, l);
			used += l;
		} while (n > 0 || (n < 0 && errno == EPIPE));	/* EPIPE: records overwritten */
	}
}
