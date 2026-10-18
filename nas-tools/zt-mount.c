/* zt-mount TYPE SRC DIR [OPTS] -- minimal mount(2) for the BusyBox 1.19 initramfs.
 * zt-mount -u DIR            -- umount(2) (BusyBox 1.19 here has no umount).
 * Omit OPTS for a normal read-write mount.  OPTS "ro" or "ro,<fs data>"
 * mounts read-only; any other value is passed verbatim as filesystem data. */
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
int main(int c, char **v)
{
	unsigned long flags = 0;
	char *data = c > 4 ? v[4] : NULL;

	if (c == 3 && !strcmp(v[1], "-u")) {
		if (umount(v[2])) { perror("umount"); return 1; }
		return 0;
	}
	if (c < 4) { fprintf(stderr, "usage: %s TYPE SRC DIR [OPTS]\n", v[0]); return 2; }
	if (data && (!strcmp(data, "ro") || !strncmp(data, "ro,", 3))) {
		flags |= MS_RDONLY;
		data = data[2] ? data + 3 : NULL;
	}
	if (mount(v[2], v[3], v[1], flags, data)) { perror("mount"); return 1; }
	return 0;
}
