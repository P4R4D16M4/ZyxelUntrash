/* zt-i2c -- read-only SMBus helper (no writes).
 *   zt-i2c scan BUS           probe 0x03-0x77 with an SMBus read-byte
 *   zt-i2c get  BUS ADDR REG  [b|w]   read byte/word data
 *   zt-i2c dump BUS ADDR      read byte data 0x00-0xff
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

static int xfer(int fd, char rw, unsigned char cmd, int size, union i2c_smbus_data *d)
{
	struct i2c_smbus_ioctl_data a = { rw, cmd, size, d };
	return ioctl(fd, I2C_SMBUS, &a);
}

static int open_bus(const char *bus)
{
	char p[32];
	snprintf(p, sizeof(p), "/dev/i2c-%s", bus);
	int fd = open(p, O_RDWR);
	if (fd < 0) { perror(p); exit(1); }
	return fd;
}

int main(int c, char **v)
{
	union i2c_smbus_data d;
	if (c >= 3 && !strcmp(v[1], "scan")) {
		int fd = open_bus(v[2]);
		for (int a = 0x03; a <= 0x77; a++) {
			if (ioctl(fd, I2C_SLAVE_FORCE, a) < 0) continue;
			if (xfer(fd, I2C_SMBUS_READ, 0, I2C_SMBUS_BYTE, &d) == 0)
				printf("0x%02x present (byte=0x%02x)\n", a, d.byte);
		}
		return 0;
	}
	if (c >= 5 && !strcmp(v[1], "get")) {
		int fd = open_bus(v[2]);
		int w = c > 5 && v[5][0] == 'w';
		ioctl(fd, I2C_SLAVE_FORCE, (int)strtol(v[3], 0, 0));
		if (xfer(fd, I2C_SMBUS_READ, strtol(v[4], 0, 0),
			 w ? I2C_SMBUS_WORD_DATA : I2C_SMBUS_BYTE_DATA, &d)) { perror("read"); return 1; }
		printf(w ? "0x%04x\n" : "0x%02x\n", w ? d.word : d.byte);
		return 0;
	}
	if (c >= 4 && !strcmp(v[1], "dump")) {
		int fd = open_bus(v[2]);
		ioctl(fd, I2C_SLAVE_FORCE, (int)strtol(v[3], 0, 0));
		for (int r = 0; r < 256; r++) {
			if (r % 16 == 0) printf("%02x:", r);
			if (xfer(fd, I2C_SMBUS_READ, r, I2C_SMBUS_BYTE_DATA, &d)) printf(" --");
			else printf(" %02x", d.byte);
			if (r % 16 == 15) printf("\n");
		}
		return 0;
	}
	fprintf(stderr, "usage: zt-i2c scan BUS | get BUS ADDR REG [b|w] | dump BUS ADDR\n");
	return 2;
}
