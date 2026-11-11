# ZyxelUntrash

**UntrashOS for the Zyxel NAS542: a maintained Linux for the NAS, the NAS whose vendor firmware is out of support.**

UntrashOS replaces the Zyxel firmware with Debian 13 on Linux 6.6 LTS and keeps
what you have: your disks, volumes, shares, users and passwords are taken over
from the Zyxel system, nothing is reformatted.  It is installed from a USB
stick, it can be removed again (the original firmware is restored from the
backup the installer made), and it updates itself with signed A/B system images.

- **Untrash Desk**, a web interface in the browser: files, shares, users,
  storage and RAID, network, backups, cloud sync, downloads, media server,
  broadcast channels, terminal, updates, logs; German, English, French
- **Everything the Zyxel firmware did**, on current software: SMB, FTP, NFS,
  WebDAV, DLNA media server, Time Machine, iSCSI, USB copy button, power
  schedule, fan control, LEDs and the buzzer
- **Ad filter** for the whole home network: the NAS answers DNS and blocks
  ads and trackers for every device that uses it, with block lists
  (StevenBlack, Hagezi), own allow/block rules, a query log and statistics
- **All four bays**, including the two behind the ASM1061 PCIe controller 
- **Safe by construction**: read-only, verified system image (erofs +
  dm-verity), two slots with automatic fallback, hardware watchdog

### New in 1.1

- **UntrashMesh**: several UntrashOS devices form one encrypted network
  (WireGuard), at home and over the internet, without a cloud provider or a
  fixed IP address.  Members reach each other by name (`<name>.mesh`), offer
  each other shares read-only or read/write (*partner volumes*) and can keep
  an **off-site mirror** of a data volume on another member (DRBD)
- **UntrashApp** pairing: the phone app joins the mesh and can be a second
  factor for signing in to the Desk
- **Office**: documents on the NAS open and save in the browser through an
  external office server (Collabora Online, Nextcloud Office, ONLYOFFICE; WOPI)
- **Updates from the release page**: the NAS finds new signed releases on
  GitHub by itself
- **Themes**: dark, light, high contrast or automatic, colour-vision palettes,
  reduced motion; stored per user
- **Sounds**: a melody editor for the buzzer, with import and export of sound sets
- **Feedback**: prepares a bug report as a GitHub issue, with optional
  anonymised system info; nothing is sent automatically
  
## New in 1.2.2

- **UntrashKey**: a paired USB stick as a hardware key; chosen areas (SSH,
  terminal, access, system, …) work only while it is plugged in
- **Phone view** of the Desk: one app at a time, the phone's back button works
- The Desk shows the actual model (NAS520, NAS540, NAS542) and its bays

## New in 1.2

- **Smart home**: the NAS appears as a device in Home Assistant or any other
  MQTT smart home
- **RAM boost**: an SSD in any bay becomes a memory extension for the 1 GB NAS
- **Nextcloud** as an UntrashMesh member: it keeps the mesh's address book,
  follows file changes on the NAS shares and reaches them through an encrypted
  tunnel, without port forwarding at home

## Documentation

- [User guide](docs/user-guide/README.md) — installation, Desk, every app ([PDF](docs/user-guide/UntrashOS-User-Guide.pdf))
- [Building](docs/build.md) — from source to the installer stick
- [Hardware reference](docs/hardware/README.md) — SoC, memory map, boot chain, board peripherals and the pitfalls, for anyone porting further
- [Stock takeover](untrashos/docs/architecture/stock-takeover.md) — how the Zyxel configuration is taken over; [design system](untrashos/docs/architecture/untrash-design.md)

This repository is the firmware for the NAS542: kernel, loader, installer and
board support.  The operating system itself (Desk, services, image build) is
[UntrashOS](https://github.com/P4R4D16M4/UntrashOS), included here as the
submodule `untrashos/`; clone with `git clone --recursive`.

## Status

UntrashOS runs as the daily system on a NAS542 with four disks.  The NAS540
and the two-bay NAS520 are the same platform; UntrashOS recognizes the model
from the stock firmware and shows it, but it has not been run on a NAS520
([hardware reference, §10](docs/hardware/README.md#10-models-nas520-nas540-nas542)).  The images
contain no proprietary firmware: the network firmware of the SoC (NXP PFE) is
extracted on the NAS from the stock kernel already in its flash.  Everything
on the stick is built from this repository.

## Download and install

You do not need to build anything:

1. Download the stick image
   [`untrash-stick-1.2.2.img.xz`](https://github.com/P4R4D16M4/ZyxelUntrash/releases/download/1.2.2/untrash-stick-1.2.2.img.xz)
   (about 270 MB).  All versions and the update files for existing
   installations are on the [Releases](https://github.com/P4R4D16M4/ZyxelUntrash/releases) page.
2. Write it to a USB stick of at least 4 GB with
   [balenaEtcher](https://etcher.balena.io/) or
   [Raspberry Pi Imager](https://www.raspberrypi.com/software/): choose the
   `.img.xz` as it is, choose the stick, write.  Everything on the stick is erased.
3. Plug the stick into the NAS542 (running the Zyxel firmware) and follow the
   [user guide](docs/user-guide/README.md#1-installation).

To build the image yourself, see [Building](docs/build.md).

## License

UntrashOS is free software under the GNU General Public License v3 ([LICENSE](LICENSE)).
The kernel patches in `kernel/patches/` are, like Linux, GPL-2.0.  Third-party
parts keep their licenses: TweetNaCl (public domain), xterm.js (MIT), pdf.js
(Apache-2.0), hls.js (Apache-2.0), each next to its files.

UntrashOS is not affiliated with Zyxel.  Installing it replaces the firmware of
your device; you do it at your own risk, after the backup the installer makes.
