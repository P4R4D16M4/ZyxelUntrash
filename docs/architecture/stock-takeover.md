# Übernahme einer Stock-NAS542 (Kerneigenschaft 4a) – Stand 2026-10-09

Bezug: `untrash-os-concept.md` §4a. Werkzeug: `os/image/untrash-files/usr/sbin/untrash-import-zyxel`.
Belege: `[DEC]` dekompilierte Stock-Modelle (Firmware 5.21(ABAG.15), `web_framework/models/*.pyc`,
uncompyle6, nur lokal), `[NAND]` NAND-Abzug `mtd3-config` vom 2026-09-27, `[TEST]` Offline-Test.
Echte Namen, MACs und UUIDs dieser NAS stehen **nicht** in diesem Dokument.

**Betriebsregel (Operator, 2026-10-09):** Die Original-Plattenkonfiguration bleibt draußen, bis ein
vollständiger, sicherer Installer existiert. Bis dahin wird nur mit synthetischen Stock-Platten
(Loop-Dateien) und der NAND-Konfiguration getestet.

## 1. Plattenlayout der Stock-Firmware `[DEC storage_def/storage_func]`

Jede interne Platte: GPT, drei Partitionen, alle mit `raid`-Flag (`parted`):

| Part. | Bereich | md | Inhalt |
|---|---|---|---|
| 1 | 0 % – 2048 MB (3 997 696 Sektoren) | `md0` | Firmware, RAID1 über alle 4 Bays (`missing` für leere), Metadata **1.2**, ext4 |
| 2 | 2048 – 4096 MB (3 999 744 Sektoren) | `md1` | Swap, RAID1 wie md0 |
| 3 | 4096 MB – 100 % | `md2…md5` | Daten: `linear` (JBOD), `raid0`, `raid1` (auch „basic“ mit einer Platte), `raid5`, `raid6`, `raid10`; Metadata **1.2**, Chunk 64 KiB |

Korrektur zum Konzept: Die Stock-Firmware nutzt Metadata **1.2**, nicht 1.0.

Volumes auf einem Daten-Array (zwei Typen):
- **md:** ext4 direkt auf dem Array, Mount `/i-data/<md-uuid8>` (erste 8 Hex-Zeichen der md-UUID).
- **lvm:** PV auf dem Array, VG `vg_<md-uuid8>`, darin `vg_info_area` (100 MiB, ext4, Mount
  `/mnt/vg_info_area/<vg>`, enthält den Namen der Disk Group) und je Volume `lv_<rand8>` →
  `/i-data/<rand8>`. LVs sind linear (`lvcreate --addtag ext4 -L…`).
- ext4: `mkfs.ext4 -E discard,stride=16,stripe-width=16*n -b 4096 -j -m 0 -O large_file,extents,uninit_bg`;
  Mount `rw,usrquota,noatime,data=ordered,barrier=1`, danach `chmod 777` auf den Mountpunkt, `quotaon -u`.
- Anzeigename: `<mnt>/.system/name_label`. Systemvolume: Datei `<mnt>/.system/sysvol_<MAC ohne :>`;
  Links `/i-data/sysvol`, `/i-data/.system`, `/i-data/.media`. Standardordner `admin/download/torrent`, `music`, `photo`, `video`.
- USB: `/e-data/<uuid>`, Namenstabelle `/etc/zyxel/storage/extuuid.table` (`Name|UUID`); Dateisysteme FAT16/32, NTFS (tntfs), exFAT (FUSE), ext2/3/4, HFS+, ISO9660/UDF.

## 2. Wo die Konfiguration liegt `[NAND]`

`/etc/zyxel` ist UBIFS im UBI-Volume `ubi_config` auf NAND `mtd3` „config“ (Offset 0, 10 MiB).
80 PEB à 128 KiB, VID-Header bei 2048, Daten bei 4096. Wichtige Dateien:

| Datei | Inhalt |
|---|---|
| `ugs_conf.db` | SQLite: Benutzer, Gruppen, Mitglieder, Freigaben, Rechte (§3) |
| `py_conf` | ConfigObj: `system.hostname`, `system.servername.{servername,description,workgroupname,nomaster}`, `system.date_time.*`, `network.interface.*`, `backup.time_machine.{active,target_share}`, Dienste (http/https/ssh/ftp/…) |
| `storage/extuuid.table`, `storage/pwron.int` | USB-Namen; Einschaltverhalten |
| `conf/startup-config.conf` | zysh-Konfiguration (im Abzug 0 Byte; die DB ist maßgeblich) |
| `webdav/*.flag`, `storage/enable_nfs.flag`, `hd-idle.conf`, `pkg_conf/` | Dienstschalter, Spin-down, Pakete |
| `ssh/`, `cert/` | Host- und TLS-Schlüssel (werden nicht übernommen) |

## 3. Benutzer, Gruppen, Freigaben `[DEC ugs_comm_def/user_grp_func/share_func]`

Schema (`ugs_conf.db`): `smb_user(uid, uname, create_type, utype, passwd, description)`,
`smb_group(gid, gname, gtype, description)`, `group_member(gid, gname, uid, uname)`, `ugs_misc(key, value)`,
`smb_share(s_name, s_path, create_type, s_desc, s_enable, browseable, recycle, mdaserv_public_type, web_public)`,
`share_user_privilege(s_name, uid, uname, privilege)`, `share_group_privilege(s_name, gid, gname, privilege)`.

- UIDs: `admin` 501, Gast `pc-guest` 502, eigene Benutzer ab 504; Gruppe `everyone` GID 500 (Primärgruppe aller).
- `smb_user.passwd` = `LM:NT` (je 32 Hex) → per `pdbedit -i smbpasswd:` übernehmbar; **SMB-Passwörter bleiben gültig**.
- Unix-Passwort nur für `admin`/`root`: md5-crypt in `ugs_misc.admin_shadow_passwd`. Andere Benutzer haben keins.
- Rechte `rw`/`ro`/`deny` pro Benutzer bzw. Gruppe wirken **nur in Samba**; im Dateisystem ist alles 0777
  (`force create mode`/`force directory mode` 777). Regeln von `get_share_smbconf()`:
  `valid users` = alle rw+ro (Gruppen mit `+`), entfällt wenn nur `pc-guest` und kein ro/deny;
  `read list` = ro; `invalid users` = deny; `pc-guest` in rw/ro → `guest ok = yes`;
  gar keine Rechte → `valid users = nobody`, `invalid users = +everyone`.
  Freigaben mit `s_enable=n` oder fehlendem Pfad werden nicht ausgegeben. Papierkorb: `vfs recycle`, Ordner `recycle`.
- Global: `map to guest = Bad User`, `guest account = pc-guest`, `security = user`, Arbeitsgruppe/Name aus `py_conf`.

## 4. Befund dieser NAS (anonymisiert, `[NAND]`)

4 Benutzer (admin, Gast, 2 eigene), 1 Gruppe, 14 Freigaben (6 aktiv) auf **drei internen Volumes und einem
USB-Volume**. Alle 4 SMB-Hashes sind gültig. Keins der Volumes steckt derzeit in der NAS (Betriebsregel oben).

## 5. Importer `untrash-import-zyxel`

| Befehl | Wirkung | schreibt |
|---|---|---|
| `config-from-nand DEST` | UBI auf NAND „config“ anhängen (Elter-MTD nicht schreibbar → UBI `ro_mode`, wie `rootfs1` in den Loadern), UBIFS `ro`, Baum nach DEST kopieren | nur DEST |
| `volumes [--mount]` | Stock-Arrays per `mdadm --examine` finden und klassifizieren; `--mount`: `mdadm --assemble --readonly`, LVM mit `metadata_read_only=1` + `read_only_volume_list`, ext4 `ro,noload` unter `/i-data` (tmpfs), sysvol-Links | nichts auf den Platten |
| `release` | aushängen, VGs deaktivieren, Arrays stoppen | – |
| `plan CONFIG` | Benutzer, Gruppen, Freigaben, Pfad vorhanden/fehlt | – |
| `render CONFIG [--out F]` | smb.conf nach den Stock-Regeln | F |
| `apply CONFIG --yes-take-over` | Konfliktprüfung (UID/GID/Namen), Kopie nach `/etc/untrash/zyxel/stock-config`, Gruppen/Benutzer mit Stock-IDs, admin-Hash, SMB-Hashes in tdbsam, `takeover.json`; danach `untrash-zyxel.service` (Volumes `rw,usrquota` nach `e2fsck -p`, smb.conf, Samba) | System + nach Bestätigung die Volumes |

Schutz im Image (`mkslot-erofs.sh`): `mdadm.conf` `AUTO -all` und LVM `auto_activation_volume_list = []`.
Damit setzen udev-Regeln eingesteckte Stock-Platten nie selbst zusammen. Samba ist bis `apply` aus.

Bewusste Abweichungen vom Stock: tdbsam statt smbpasswd-Datei, kein LANMAN, kein `wide links`, keine Drucker,
kein AFP (Time Machine später über `vfs_fruit`). Alte Pfade (`/i-data/<id>/…`, `/i-data/sysvol`) bleiben gleich.

Kernel **V600g** (`configs/v600g-system.fragment`, Quelle `6b60fa964`, zImage `8036fb38…`): V600f + NAND-Partition
„config“ (nur lesend) + Module md linear/raid0/raid10, Quota (`QFMT_V2`, fest `QUOTA`), dm snapshot/thin/mirror/crypt/raid,
FAT/vFAT/exFAT/NTFS3/HFS+/ISO9660/UDF/XFS/F2FS/FUSE. Image: + python3, lvm2, samba, mtd-utils, quota, parted, sqlite3.

## 6. Tests

- `[TEST]` `os/image/tests/test_import_zyxel.py`: synthetische Stock-DB, alle Rechte-Fälle. Mit
  `ZT_STOCK_SHARE_FUNC=<dekompilierte share_func.py>` werden die Freigaben gegen die Original-Funktion
  verglichen: **identisch** (6/6 Freigaben, 2026-10-09). Lauf gegen die echte DB-Kopie: ohne Fehler.
- Auf der NAS (Freigabe nötig): `os/image/tests/nas-takeover-selftest.sh` baut drei Stock-Platten als
  Sparse-Loop-Dateien mit den Stock-Befehlen (RAID1+LVM über zwei, „basic“+ext4 auf einer) und prüft
  ro-Mount, sysvol, Eigentümer, Schreibschutz und **SHA-256-Gleichheit der Plattenabbilder** nach mount+release.
  Dazu `config-from-nand` und Vergleich von `ugs_conf.db` mit der PC-Kopie (Lesepfad-Beweis).

### Hardwarelauf P4a (2026-10-09)
- Slot `p4a-v600g-1` nach `ut-sys-a` (Rescue aus Debian-Reboot, Rücklese-SHA identisch) → Debian `running`.
  Alte `etc.upper/ld.so.cache` aus P2 → unter p4a `ldconfig` (Overlay-Update-Problem, s. p2-image „Offen“).
- **NAND unter Debian nicht verfügbar:** `comcerto-nand` bricht nach kexec sicher ab
  (`unsafe ECC precondition: gen=00080400 cs=00000010`, -117): der Loader hinterlässt den ECC-Block in diesem Zustand.
  `config-from-nand` geht deshalb nur im Loader oder unter Stock → Installer sichert `/etc/zyxel` vorher (installer-plan.md).
- `CONFIG_BLK_DEV_LOOP` fehlte → Kernel **V600h** (= V600g + Loop-Modul, zImage `24f22428…`), Slot `p4a-v600h-2`
  (Kopf `69aea306…`, Trailer `630b013b…`, verity `2c26b967…`).
- `nas-takeover-selftest.sh` **PASS**: Stock-Partitionierung ergibt exakt die Stock-Größen (3 997 696 / 3 999 744 Sektoren);
  LVM-Volume (`vg_<md8>/lv_<id>`, `vg_info_area` mit Disk-Group-Namen) und md-Volume erkannt und `ro` eingehängt,
  sysvol-Link, Eigentümer 504:500 erhalten, Schreiben abgewiesen, **alle drei Plattenabbilder nach mount+release bitidentisch**.
  Neueres mdadm verweigert `--chunk` bei RAID1 (Stock-mdadm erlaubte es).
- smbd/nmbd bleiben aus (nur Alias-Links `smb`/`nmb`), `AUTO -all` aktiv, Module raid0/raid10/linear/quota_v2/ntfs3/exfat/vfat laden.

## 7. Offen

- NFS (`/etc/exports` + Flag), FTP, WebDAV, Time Machine aus `py_conf` übernehmen.
- Quota-Grenzen liegen in `aquota.user` auf den Volumes (bleiben erhalten); Anzeige/Verwaltung fehlt.
- USB-Volumes (`/e-data`) automatisch einhängen; Namen aus `extuuid.table`.
- Benutzer ohne Unix-Passwort: Cockpit-Anmeldung erst nach Passwortwechsel (SMB-Hash lässt sich nicht umwandeln).
- Installer-Pfad (Systemslots als Dateien auf dem Altbestand, Konzept §4a.2) – Voraussetzung für die Originalplatten.

## 8. Weg B vollständig: Einstellungen und Stock-Funktionen (2026-10-09)

`untrash-config import-stock` (nach `untrash-import-zyxel apply`, Dienst `untrash-takeover-firstboot`) legt
`/etc/untrash/settings.json` an; `untrash-config render/apply` erzeugt daraus die Systemdateien. Ein Dienst läuft nur,
wenn er unter Stock an war. Quellen `[DEC]`/`[NAND]`, Test `os/image/tests/test_untrash_config.py`.

| Stock | Quelle | UntrashOS |
|---|---|---|
| Benutzer, Gruppen, Freigaben, Rechte, SMB-Passwörter, admin-Passwort | `ugs_conf.db` | wie §5; Login in Untrash Desk und FTP mit dem **SMB-Passwort** (NT-Hash gegen tdbsam, `pylib/untrash_auth.py`, PAM `pam_exec`) |
| Rechnername, NetBIOS-Name, Beschreibung, Arbeitsgruppe | `py_conf system.*` | `/etc/hostname`, smb.conf (`/etc/untrash/smb-extra.json`) |
| Zeitzone `+01:00/Stadt`, NTP-Server | `system.date_time` | IANA-Zone (Stadt → `Region/Stadt`), chrony |
| LAN 1/2 DHCP oder fest, MTU, DNS manuell | `network.interface.egiga0/1, nameserver` | `05-untrash-eth0/1.network`; Stock-MACs aus dem Env (PartnerKey `device.env`) |
| SSH an/Port/SFTP | `system.service.ssh` | sshd, `AllowUsers root admin`, admin mit Passwort |
| FTP (pure-ftpd): Port, TLS, Anonym, Verbindungen, Passivbereich, Raten | `system.service.ftp` | vsftpd; je Benutzer eine Sicht `/run/untrash/ftp/<user>` aus Bind-Mounts mit genau den Freigaberechten (ro/rw) |
| NFS | `storage/enable_nfs.flag`, exports | nfs-kernel-server (Kernel V600i: NFSD) |
| Medienserver (DLNA) je Freigabe Video/Foto/Musik | `mdaserv_public_type` (1/2/4) | minidlna `media_dir=VPA,…` |
| Time Machine (AFP) | `backup.time_machine` | SMB mit `vfs_fruit` auf der Zielfreigabe, Avahi |
| Papierkorb je Freigabe, Ablauf in Tagen | `recycle`, `ugs_misc.rbm_expire_day` | `vfs recycle`, Timer `untrash-recycle-expire` |
| Platten-Spin-down | `hd-idle.conf`, `pwrmg.pwr_turnOffHD` | hd-idle |
| USB-Volumes `/e-data/<md5(UUID)>`, Namen | `storage/extuuid.table`, `storage_func` | `untrash-usb` (udev), gleiche Pfade und Mount-Optionen je Dateisystem |
| Benutzer-Quotas | `aquota.user` auf den Volumes | bleiben wirksam (`usrquota`, `quotaon`); keine Verwaltung in der Oberfläche |
| RAID-/Volume-Verwaltung (anlegen basic/JBOD/0/1/5/6/10, Volume direkt oder Disk Group/LVM, reparieren, Platten hinzufügen, basic→1→5→6, Reserveplatte, auf Plattengröße erweitern, löschen, umbenennen; LVM-Volumes anlegen/vergrößern/löschen) | `storage_func`/`storage_submain` `[DEC]` | `untrash-storage` (gleiche Befehle, gleiches Format: GPT p1/p2/p3, md0/md1 RAID1 über 4 Schächte, Metadata 1.2, Chunk 64, ext4-Flags/Stride, `/i-data/<uuid8>`, `vg_<uuid8>`/`vg_info_area`/`lv_<id>`, Systemvolume-Marke, Standardordner); Desk „Speicher“ mit Auftragslog, Text-Bestätigung FORMATIEREN/LÖSCHEN; Test `os/image/tests/test-storage-host.sh` (73 Prüfungen) `[TEST]`. Abweichung: `--chunk` nur bei Levels mit Striping (neues mdadm lehnt es bei RAID1 ab); Schacht = SCSI-Host 0–3 (auf Hardware noch zu prüfen) |
| WebDAV (`/etc/zyxel/webdav/dav.flag`, `dav_anonymous.flag`) | Apache mod_dav, `parse_smb_conf.py` `[DEC]` | `apache2-bin` + `mod_authnz_external` als `untrash-webdav.service`, `http://NAS:5002/webdav/<Freigabe>`, https 5003 (wie Stock); Lesen für ro+rw, Schreiben nur rw (Rechte = Samba-Regel `user_access`), anonym = Gast-Freigaben; Anmeldung mit SMB-Passwort über `untrash-authd` (root, Socket) – Apache (www-data) sieht keine Hashes; Test mit echtem Apache `os/image/tests/test-webdav-host.py` `[TEST]` |
| DynDNS (`system.service.dydns`: provider, username, password, hostname) | `dydns_main_model` `[DEC]` (Stock: inadyn) | inadyn 2 (`/etc/inadyn.conf` 0600); Anbieter dyndns, noip, 3322, zoneedit (+ duckdns, freedns, dynv6); Stock „dhs“/„myzyxelth“ gibt es nicht mehr → `unsupported` |
| E-Mail-Benachrichtigung (`maintenance.log.mail`: address, authentication, username, password, from, send-alerts-to, send-log-to, subject, alert, levelall, schedule, day, hour, miniute) | `zylog_main_model` `[DEC]` | `untrash-notify` (smtplib, Port 0 = 587 STARTTLS/465/25): Warnungen bei mdadm-Ereignissen (`mdadm.conf PROGRAM`), SMART (`smartd -M exec`), Volume ≥ 95 % (Timer); Protokollbericht per `untrash-log-report.timer` (stündlich/täglich/wöchentlich wie Stock); Testmail im Desk |
| Syslog an Server (`maintenance.log.syslog`: enable, address) | `zylog_main_model` `[DEC]` | `untrash-syslog-forward` (Journal → RFC 3164/UDP) |
| Syslog-Server (`syslog-ng/enable_syslog.flag`, `syslog.table` „Pfad\|Format\|Monate“) | `syslogng_main_model` `[DEC]` | `untrash-syslogd` (514 UDP+TCP), Dateien `<Pfad>/<JJJJMM>/<Quell-IP>_<JJJJMMTT>.txt`, Formate simple/full/eigene Liste, alte Monate löschen |
| USV (apcupsd per Hotplug, `pwr_minimumUPSCapacity` → `BATTERYLEVEL`) | `pwrmg_main_model`, `/etc/apcupsd/apcupsd.conf` `[DEC]`/`[NAND]` | apcupsd, udev-Regel (APC 051d) startet ihn beim Einstecken wie Stock-`hotplug`; aus = `ups.enabled` fehlt |
| Web Publishing (`system.service.webpublish` active/port, `smb_share.web_public`) | `web_publish_main_model` `[DEC]` | Port 80: Untrash Desk liefert `/MyWeb/<Freigabe>` (öffentlich, nur lesen, index.html, CSP-Sandbox gegen Zugriff auf die Desk-Sitzung); anderer Port: Apache-VirtualHost wie Stock; Häkchen je Freigabe |
| Link-Aggregation (`network.interface.bond0`: activate, slave, mode 0–6, Adresse) | `network_main_model_back` `[DEC]` | systemd-networkd `bond0` (Modus wie Stock, miimon 100); Kernel V600j `bonding.ko`. **Hardware:** eth1 (PFE-Port 1) ist noch nicht bewiesen |
| Drucker (USB, CUPS-Rohwarteschlangen, Samba `[printers]`) | `prt_main_model`, Stock-`smb.conf` `[DEC]`/`[NAND]` | `cups-daemon`, `untrash-printer` (udev `usblp`, Name aus `system.service.printer.<Seriennr>.prt_name` oder `<Hersteller>_<Produkt>_<n>`), `[printers]` wie Stock; Kernel V600j `usblp.ko`; Desk: Liste, Aufträge löschen |
| Cloud-Apps: DropboxClient, GoogleDriveClient, Upload Manager (FTP) | `h_AppCenter.html`, `h_UploadManager.html` | `untrash-cloud` + rclone: Konten (OAuth nur mit Browser: Anmeldeseite → Rücksprung-Adresse zurück in den Desk; FTP mit verschleiertem Passwort), Aufträge Zwei-Wege (`bisync`), nur hoch (Upload Manager), nur runter, Intervall; Desk-Fenster „Cloud“; Test mit echtem rclone `os/image/tests/test-cloud-host.py` `[TEST]` |
| Download-Dienst (`dservice`: HTTP/FTP/BitTorrent/Magnet, Zielordner, beobachteter Ordner, Bandbreite, Zeitfenster, Seed-Verhältnis/-Zeit, BT-Port, DHT, Mail) | `dservice_main_model` `[DEC]`; an = kein `dservice.disable` | aria2 (`untrash-aria2.service`, RPC nur lokal mit Geheimnis), `untrash-downloads` (Zeitfenster, `.torrent`-Ordner, Mail); Desk „Downloads“ |
| Backup Planner (Archiv mit Versionen, Synchronisation, Rsync auf andere NAS; Zeitplan, Aufbewahrung, Bandbreite, Wiederherstellen) | `BackupPlanner_main_model` `[DEC]` (Stock: zydar/zysync) | `untrash-backup` mit rsync (Archiv = datierte Ordner mit Hardlinks, „N behalten“), Timer; Desk „Sicherung“; Test `test-backup-host.py`. Stock-Archive (zydar-Format) und Stock-Aufträge (`backupjob.db`) werden **nicht** übernommen |
| COPY/SYNC-Taste (`storage/usbcopy.table`, `usbzync.table`, `.ZyXELchoose*.txt`) | `copy_sync_btn_main_model` `[DEC]` | `untrash-copybtn` (kurz = Kopieren in `<Datum>/Extvolume<N>`, 3 s = Sync; rsync/rclone bisync; Sicherungsordner; LED copy-green/-red); Desk „COPY-Taste“; Test `test-copybtn-host.py` |
| RESET-Taste (2 s: IP + admin-Passwort, 7 s: Werkseinstellungen, Daten bleiben) | Stock-Hilfe `h_Trouble`/`h_Intro` | gleicher Tastendienst; 2 s = DHCP + 15 Minuten „neues admin-Passwort ohne Anmeldung“ im Desk (statt Passwort 1234); 7 s = Einstellungen/Benutzer/Freigaben auf Standard, alte Konfiguration als `/var/lib/untrash/factory-reset-*.tar`; Rückmeldung über die sys-LED (kein Summer bekannt) |
| Benutzer-Quota je Volume (GB) | `user_grp_func.set_vol_quota` (quotatool) `[DEC]` | `setquota`/`repquota` im Desk (Benutzer) |
| HTTPS für die Oberfläche (`system.service.https` active/port/force_https), Zertifikat (`/etc/zyxel/cert/default.cer`, `key/default_key.cer`) | `CA_main_model` `[DEC]`, `py_conf` `[NAND]` | Desk mit TLS-Port und Umleitung; Stock-Zertifikat wird übernommen (Clients vertrauen weiter); erzeugen/hochladen im Desk; gilt auch für FTPS und WebDAV |
| UPnP-Portfreigabe (`upnp.db` upnpInfo: Dienst, LAN-/WAN-Port) | `upnp_main_model` `[DEC]` | `untrash-upnp` (miniupnpc), Timer erneuert; Desk „Netzwerk“; CIFS/AFP/Telnet/Pakete werden nicht weitergeleitet (`unsupported`) |
| iSCSI (LIO, Datei-LUNs `<Volume>/.iscsi_Lun/`, CHAP/gegenseitig, Initiator-Liste) | `iscsi_main_model` `[DEC]` | `untrash-iscsi` direkt über configfs (Kernel V600j: `configfs`, `target_core_file`, `iscsi_target_mod` als Module); Desk „Speicher“; Test gegen echtes LIO `test-iscsi-host.py`. Stock-Ziele (LIO-Konfiguration) werden nicht automatisch übernommen, vorhandene LUN-Dateien bleiben |
| Foto-/Musik-/Video-Ansicht | Stock-Apps Photo/Music/Video | Dateien-Fenster: Bildbetrachter mit Blättern, Audio/Video-Player (Range), PDF; Inline nur für Medientypen mit CSP-Sandbox |
| Nach Stromausfall (`pwr_pwron` 1/2/3, `storage/pwron.status`), Wake-on-LAN (`pwr_wol`, `wol.status`) | `pwrmg_main_model`, `rcS2`, `rc.shutdown` `[DEC]` | `untrash-power` (MCU 0x0a, Befehle wie Stock; „wie vorher“ = beim Start an, beim sauberen Herunterfahren aus) |
| Ein-/Aus-/Neustart-Zeitplan (`backupjob.db` Typ 6/7/8, `pwrsch_default_onoff`) | `pwrmg_main_model`, `rtcAccess` `[DEC]` | Einschalten über den RTC-Alarm (Treiber `rtc-ht1382` mit `wakealarm`, gesetzt beim Herunterfahren), Aus/Neustart per Timer; Desk „Energie“. „Monatlich nach Woche“ wird nicht übernommen |
| Schächte und Schacht-LEDs | `storage_def` `DISKX_BUS_MAP`, V583 | `pylib/untrash_bays.py` (ata2 = Schacht 1, Erkennungs-GPIOs, Tabelle `/etc/untrash/bays.json`), LEDs grün/rot (`untrash-leds.timer`); Zuordnung der Schächte 2–4 auf Hardware zu bestätigen |
| Weboberfläche | – | **Untrash Desk** (`untrash-desk`, Port 80): Übersicht, Dateien, Freigaben+Rechte, Speicher/SMART/RAID, Benutzer/Gruppen, Netz, Dienste, Zeit, Energie, Papierkorb, Protokolle, Update (Slot), Ausschalten, Zurück zu Stock; Ersteinrichtung für Weg A |

Bewusst weggelassen (Operator 2026-10-10; stehen nach der Übernahme in `settings.unsupported`, wenn sie unter
Stock an waren): Telnet, iTunes-Server (DAAP), Upload Manager zu Flickr/YouTube, Memopal, myZyXELcloud, Rsync-Server.
Umgesetzt, aber erst auf Hardware zu bestätigen: Zeitplan (RTC-Alarm schaltet ein), Stromausfall, Wake-on-LAN,
bond0 über eth0+eth1, Zuordnung der Schächte 2–4.

**Auftrag 2026-10-10:** alle diese Funktionen werden nachgebaut, außer Telnet. Die Cloud-Apps sind ausdrücklich
eingeschlossen (DropboxClient, GoogleDriveClient, Upload Manager Flickr/YouTube/FTP, Memopal, myZyXELcloud; Plan
und offene Punkte in `NEXT-SESSION-HANDOFF.md` oben).
