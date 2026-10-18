/* zt-tcpbench -- raw TCP throughput on the NAS without iperf.
 *   zt-tcpbench sink PORT       accept one connection, discard, report MB/s
 *   zt-tcpbench source PORT MB  accept one connection, send MB MiB, report
 * The PC connects outbound (no host firewall change), e.g. with
 *   head -c 500M /dev/zero | nc -N 169.254.100.64 PORT   /  nc ... > /dev/null */
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	static char buf[65536];
	struct sockaddr_in a = { .sin_family = AF_INET };
	long long total = 0, want;
	int one = 1, l, c;
	ssize_t n;
	double t0;

	if (argc < 3)
		return 2;
	a.sin_port = htons(atoi(argv[2]));
	l = socket(AF_INET, SOCK_STREAM, 0);
	setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (bind(l, (void *)&a, sizeof(a)) || listen(l, 1))
		return perror("bind"), 1;
	c = accept(l, NULL, NULL);
	t0 = now();
	if (!strcmp(argv[1], "sink")) {
		while ((n = read(c, buf, sizeof(buf))) > 0)
			total += n;
	} else {
		want = atoll(argc > 3 ? argv[3] : "100") << 20;
		while (total < want && (n = write(c, buf, sizeof(buf))) > 0)
			total += n;
	}
	close(c);
	printf("%s %lld bytes in %.2f s = %.1f MB/s\n", argv[1], total,
	       now() - t0, total / (now() - t0) / 1e6);
	return 0;
}
