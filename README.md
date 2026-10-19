# UntrashOS

**A maintained Linux for the Zyxel NAS542, the NAS whose vendor firmware is out of support.**

UntrashOS replaces the Zyxel firmware with Debian 13 on Linux 6.6 LTS and keeps
what you have: your disks, volumes, shares, users and passwords are taken over
from the Zyxel system, nothing is reformatted.  It is installed from a USB
stick, it can be removed again (the original firmware is restored from the
backup the installer made), and it updates itself with signed A/B system images.

- **Untrash Desk**, a web interface in the browser: files, shares, users,
  storage and RAID, network, backups, cloud sync, downloads, media server,
  broadcast channels, ad filter, terminal, updates, logs; German, English, French
- **Everything the Zyxel firmware did**, on current software: SMB, FTP, NFS,
  WebDAV, DLNA media server, Time Machine, iSCSI, USB copy button, power
  schedule, fan control, LEDs and the buzzer
- **All four bays**, including the two behind the ASM1061 PCIe controller 
- **Safe by construction**: read-only, verified system image (erofs +
  dm-verity), two slots with automatic fallback, hardware watchdog

## Documentation

- [User guide](docs/user-guide/README.md) — installation, Desk, every app ([PDF](docs/user-guide/UntrashOS-User-Guide.pdf))
- [Building](docs/build.md) — from source to the installer stick
- [Hardware reference](docs/hardware/README.md) — SoC, memory map, boot chain, board peripherals and the pitfalls, for anyone porting further
- [Stock takeover](docs/architecture/stock-takeover.md) — how the Zyxel configuration is taken over; [design system](docs/architecture/untrash-design.md)

## Status

UntrashOS runs as the daily system on a NAS542 with four disks.  The images
contain no proprietary firmware: the network firmware of the SoC (NXP PFE) is
extracted on the NAS from the stock kernel already in its flash.  Everything
on the stick is built from this repository.

**Download:** the installer stick image and the update file for existing
installations are on the [Releases](https://github.com/P4R4D16M4/ZyxelUntrash/releases)
page.  Image writers such as balenaEtcher and Raspberry Pi Imager write the
`.img.xz` directly; otherwise unpack it with `xz -d` first.  Then follow the
[user guide](docs/user-guide/README.md).  You can also build the image yourself
([Building](docs/build.md)).

## License

UntrashOS is free software under the GNU General Public License v3 ([LICENSE](LICENSE)).
The kernel patches in `kernel/patches/` are, like Linux, GPL-2.0.  Third-party
parts keep their licenses: TweetNaCl (public domain), xterm.js (MIT), pdf.js
(Apache-2.0), hls.js (Apache-2.0), each next to its files.

UntrashOS is not affiliated with Zyxel.  Installing it replaces the firmware of
your device; you do it at your own risk, after the backup the installer makes.
