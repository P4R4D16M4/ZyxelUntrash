/* zt-smart -- read-only ATA SMART query via SG_IO ATA PASS-THROUGH(16).
 * Only non-data/PIO-in read commands are issued: SMART RETURN STATUS (0xDA)
 * and SMART READ DATA (0xD0).  No SMART write/enable/self-test commands.
 *
 *   zt-smart /dev/sdX
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <scsi/sg.h>

static int smart(int fd, unsigned char feature, unsigned char *buf, unsigned char *sense)
{
	unsigned char cdb[16] = { 0x85 };
	sg_io_hdr_t io;

	if (buf) {
		cdb[1] = 4 << 1;	/* PIO data-in */
		cdb[2] = 0x0e;		/* T_DIR in, BYT_BLOK, T_LENGTH = sector count */
		cdb[6] = 1;		/* one sector */
	} else {
		cdb[1] = 3 << 1;	/* non-data */
		cdb[2] = 0x20;		/* CK_COND: return the ATA registers */
	}
	cdb[4] = feature;
	cdb[10] = 0x4f;			/* LBA mid */
	cdb[12] = 0xc2;			/* LBA high */
	cdb[14] = 0xb0;			/* SMART */
	memset(&io, 0, sizeof(io));
	io.interface_id = 'S';
	io.cmd_len = sizeof(cdb);
	io.cmdp = cdb;
	io.dxfer_direction = buf ? SG_DXFER_FROM_DEV : SG_DXFER_NONE;
	io.dxferp = buf;
	io.dxfer_len = buf ? 512 : 0;
	io.sbp = sense;
	io.mx_sb_len = 32;
	io.timeout = 15000;
	return ioctl(fd, SG_IO, &io) < 0 ? -1 : io.sb_len_wr;
}

static const char *name(int id)
{
	switch (id) {
	case 1: return "Raw_Read_Error_Rate";
	case 3: return "Spin_Up_Time";
	case 4: return "Start_Stop_Count";
	case 5: return "Reallocated_Sector_Ct";
	case 7: return "Seek_Error_Rate";
	case 9: return "Power_On_Hours";
	case 10: return "Spin_Retry_Count";
	case 12: return "Power_Cycle_Count";
	case 187: return "Reported_Uncorrect";
	case 188: return "Command_Timeout";
	case 190: return "Airflow_Temperature";
	case 193: return "Load_Cycle_Count";
	case 194: return "Temperature";
	case 197: return "Current_Pending_Sector";
	case 198: return "Offline_Uncorrectable";
	case 199: return "UDMA_CRC_Error_Count";
	default: return "";
	}
}

int main(int argc, char **argv)
{
	unsigned char buf[512], sense[32];
	int fd, i, n;

	if (argc != 2) {
		fprintf(stderr, "usage: zt-smart /dev/sdX\n");
		return 2;
	}
	fd = open(argv[1], O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	n = smart(fd, 0xda, NULL, sense);
	/* Descriptor sense 0x09 carries the ATA registers; LBA mid/high 0x2c/0xf4 = threshold exceeded. */
	if (n >= 22 && sense[8] == 0x09)
		printf("health: %s (lba_mid=0x%02x lba_high=0x%02x)\n",
		       (sense[17] == 0x2c && sense[19] == 0xf4) ? "FAILING" : "PASSED",
		       sense[17], sense[19]);
	else
		printf("health: unknown (sense len %d)\n", n);
	if (smart(fd, 0xd0, buf, sense) < 0) {
		perror("SMART READ DATA");
		return 1;
	}
	printf("ID  %-24s VAL WORST RAW\n", "ATTRIBUTE");
	for (i = 0; i < 30; i++) {
		unsigned char *a = buf + 2 + i * 12;
		unsigned long long raw = 0;
		int b;

		if (!a[0])
			continue;
		for (b = 5; b >= 0; b--)
			raw = (raw << 8) | a[5 + b];
		printf("%3d %-24s %3d %5d %llu\n", a[0], name(a[0]), a[3], a[4], raw);
	}
	return 0;
}
