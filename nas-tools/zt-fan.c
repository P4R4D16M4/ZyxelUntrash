/* zt-fan -- NAS542 fan control, re-implementation of the stock app_wd loop.
 *
 * Stock (/usr/sbin/app_wd, 521ABAG15B1): temperature = board MCU register 0x07
 * (I2C bus 0, address 0x0a, degrees C), fan RPM = register 0x08.  PWM4 low time
 * (0x9045802C, period 5000 set by Barebox in 0x90458028) from the table below,
 * index = (T - 23) / 7 clamped to 0..6.  70..74 C four times -> alert,
 * >= 75 C four times -> shutdown.
 *
 * Deviation from stock: an unreadable/implausible temperature selects 80 %
 * (stock fell back to 20 %).  Only the table values are ever written, and only
 * to 0x9045802C; the MCU is only read.
 *
 *   zt-fan            run the control loop (logs to /dev/kmsg; every round
 *                     also /run/untrash/fan.json for the Desk status window)
 *   zt-fan status     print temperature, RPM register and PWM low time
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#define PWM_BASE	0x90458000UL
#define PWM4_MAX	0x28
#define PWM4_LOW	0x2c
#define MCU_ADDR	0x0a
#define MCU_TEMP	0x07
#define MCU_RPM		0x08
#define PERIOD_S	10

static const uint32_t low_table[7] = { 4000, 3500, 3000, 2500, 2000, 1500, 1000 };
static volatile uint32_t *pwm;
static int kmsg = -1;

static void logmsg(const char *fmt, int a, int b, int c)
{
	char buf[160];
	int n = snprintf(buf, sizeof(buf), "<5>zt-fan: ");
	n += snprintf(buf + n, sizeof(buf) - n, fmt, a, b, c);
	if (kmsg >= 0)
		write(kmsg, buf, n);
	else
		fprintf(stderr, "%s", buf + 4);
}

static int mcu_read(int fd, uint8_t reg)
{
	union i2c_smbus_data d;
	struct i2c_smbus_ioctl_data a = { I2C_SMBUS_READ, reg, I2C_SMBUS_BYTE_DATA, &d };

	if (ioctl(fd, I2C_SMBUS, &a) < 0)
		return -1;
	return d.byte;
}

/* Desk status: last reading, written atomically, best effort. */
static void state_write(int t, int rpm, int lvl)
{
	FILE *f = fopen("/run/untrash/fan.json.tmp", "w");

	if (!f)
		return;
	fprintf(f, "{\"temp_c\": %d, \"rpm_reg\": %d, \"level\": %d, \"pwm_low\": %u, \"time\": %ld}\n",
		t, rpm, lvl, (unsigned)low_table[lvl], (long)time(NULL));
	if (fclose(f) == 0)
		rename("/run/untrash/fan.json.tmp", "/run/untrash/fan.json");
}

static int level_for(int t)
{
	int idx;

	if (t <= 0 || t > 120)	/* unreadable or implausible: fail safe */
		return 6;
	idx = (t - 23) / 7;
	if (t < 23 || idx < 0)
		idx = 0;
	return idx > 6 ? 6 : idx;
}

int main(int argc, char **argv)
{
	int mfd, ifd, hot = 0, alert = 0, last = -1;

	ifd = open("/dev/i2c-0", O_RDWR);
	if (ifd < 0 || ioctl(ifd, I2C_SLAVE, MCU_ADDR) < 0) {
		perror("i2c-0/0x0a");
		return 1;
	}
	mfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mfd < 0) {
		perror("/dev/mem");
		return 1;
	}
	pwm = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, PWM_BASE);
	if (pwm == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	if (argc > 1 && !strcmp(argv[1], "status")) {
		printf("temp=%d rpmreg=%d pwm4_max=0x%08x pwm4_low=%u\n",
		       mcu_read(ifd, MCU_TEMP), mcu_read(ifd, MCU_RPM),
		       pwm[PWM4_MAX / 4], pwm[PWM4_LOW / 4]);
		return 0;
	}
	/* Barebox must have enabled PWM4 with period 5000; otherwise do nothing. */
	if ((pwm[PWM4_MAX / 4] & 0x8000ffff) != (0x80000000 | 5000)) {
		fprintf(stderr, "PWM4 not configured by Barebox (0x%08x); refusing\n",
			pwm[PWM4_MAX / 4]);
		return 1;
	}
	kmsg = open("/dev/kmsg", O_WRONLY);
	for (;;) {
		int t = mcu_read(ifd, MCU_TEMP);
		int lvl = level_for(t);

		if (lvl != last) {
			pwm[PWM4_LOW / 4] = low_table[lvl];
			logmsg("temp=%d C level=%d low=%d\n", t, lvl, (int)low_table[lvl]);
			last = lvl;
		}
		state_write(t, mcu_read(ifd, MCU_RPM), lvl);
		hot = (t >= 75 && t <= 120) ? hot + 1 : 0;
		alert = (t >= 70 && t <= 120) ? alert + 1 : 0;
		if (alert == 4)
			logmsg("ALERT temperature %d C (%d/%d)\n", t, 0, 0);
		if (hot >= 4) {
			logmsg("temperature %d C too high, powering off (%d/%d)\n", t, 0, 0);
			sync();
			execl("/sbin/zt-poweroff", "zt-poweroff", (char *)NULL);
			return 1;
		}
		sleep(PERIOD_S);
	}
}
