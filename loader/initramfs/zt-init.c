// SPDX-License-Identifier: GPL-2.0-only
/* ZyxelUntrash V565 PID 1: mount the pseudo filesystems the stripped BusyBox
 * 1.19 cannot mount itself, then hand over to /etc/rc.ssh. */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static void mnt(const char *src, const char *dst, const char *type,
		unsigned long flags, const char *data)
{
	mkdir(dst, 0755);
	if (mount(src, dst, type, flags, data))
		fprintf(stderr, "ZT-V565:MOUNT_FAIL %s %s\n", dst, strerror(errno));
}

int main(void)
{
	char *const argv[] = { "/bin/sh", "/etc/rc.ssh", NULL };
	char *const envp[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root",
			       "TERM=vt100", NULL };

	mnt("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mnt("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mnt("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
	mnt("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "gid=5,mode=620,ptmxmode=666");
	mnt("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
	mnt("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
	fprintf(stderr, "ZT-V565:INIT_MOUNTED\n");
	execve(argv[0], argv, envp);
	fprintf(stderr, "ZT-V565:EXEC_FAIL %s\n", strerror(errno));
	for (;;)
		pause();
}
