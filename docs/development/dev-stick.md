# Dev sticks

A dev stick is a regular UntrashOS stick of a **development NAS** that also opens
service SSH for the project's developers. Each development NAS has exactly one dev
stick, and it stays with that NAS.

## What is on it

| Path on the stick | Purpose |
|---|---|
| everything of a regular stick | installer, system image, loader, PartnerKey (`docs/user-guide`) |
| `UNTRASH/install-*/` | flash backup and `device.env` of that NAS's install run: way D, loader updates, PFE firmware source |
| `UNTRASH/ssh/authorized_keys` | public SSH keys of the developers (the dev part) |

The install-run folder belongs to one NAS. When a dev stick is written anew, copy that
folder back from the previous stick or from a backup on the PC. Without it the stick can
neither take the NAS back to stock nor update its loader.

## How the key path works

With the stick plugged in **at boot**, `untrash-servicekey` copies the keys into a tmpfs
(`/run/untrash/servicekey/`) and starts `ssh`. These keys can then log in as `root`. The
keys never reach the disk. Without the stick at the next boot, the access is gone. The
installer (`untrash.installer=1`) has no SSH.

```bash
ssh -F /dev/null -o UserKnownHostsFile=<per-NAS known_hosts> root@<LAN_IP>
```

Keep one `known_hosts` file per NAS. A reinstall (way A/B/C) creates new host keys.

**With UntrashKey on** (Desk → System → UntrashKey, off by default) the boot-time path
above steps aside: the dev stick has to be paired with its NAS like any key, and its
`UNTRASH/ssh/authorized_keys` then work while it is plugged in, not only at boot
(`untrashos/docs/architecture/untrashkey.md`). Pairing writes `UNTRASH/untrashkey/` onto
the stick; copy it back with `install-*` when the stick is written anew.

## Adding a developer

Every developer adds their own public key. Each one is a single line in
`authorized_keys`:

```bash
tools/dev-stick.sh /media/$USER/UNTRASHPK ~/.ssh/id_ed25519.pub
tools/dev-stick.sh /media/$USER/UNTRASHPK --list
```

Private keys never go onto the stick or into the repository. To remove a developer,
delete that developer's line.

## Rules

- Dev sticks are for development NAS only. A stick that goes to a user carries no
  `UNTRASH/ssh/`.
- Loader updates on a development NAS: `UPDATE=1` in `UNTRASH/manifest.env` plus the
  marker `UNTRASH/ROLLBACK`. The loader hands over to the stock firmware, and the
  PartnerKey writes only the loader (`UPDATE_DONE`, env unchanged).
- The USB blackbox (raw area 1–17 MiB of the stick) keeps the boot log of the last 16
  starts. Read it before writing the stick anew.
