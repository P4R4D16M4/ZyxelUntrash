# UntrashOS – Architekturkonzept (Entwurf, Stand 2026-10-08)

Status: **Vorschlag zur Entscheidung.** Nichts hiervon ist auf Hardware umgesetzt.
Entscheidungsbedürftige Punkte sind mit **[E-n]** markiert (Liste am Ende).
Belege: `[HW]` auf Hardware gesehen, `[DUMP]` aus Flash-/Firmware-Abzügen, `[PLAN]` Vorschlag.

## 0. Randbedingungen (was die Plattform hergibt)

| Punkt | Stand | Folge für das OS |
|---|---|---|
| CPU | 2× Cortex-A9 ≈1,2 GHz, ARMv7, 32 bit `[HW]` | Debian **armhf**. Kein arm64, keine schweren Stacks (Ceph, Kubernetes) |
| RAM | 1 GiB, Kernel nutzt aktuell `mem=768M` `[HW]` | Swap auf Platte + zram Pflicht, Dienste per Socket-Aktivierung |
| Bootloader | Barebox-C2K im SPI-NOR, unverändert `[DUMP]` | Lädt Kernel nur über **TFTP, NAND, NOR oder rohe SATA-Sektoren** (`sata read`). **Kein USB, kein Dateisystemzugriff** `[DUMP]` |
| Barebox-Env | Bereits durch das Projekt angepasst (TFTP zuerst, Fallback NAND kernel1), geschrieben über PartnerKey `[DUMP]` | Die Boot-Reihenfolge ist anpassbar; das ist aber ein Flash-Schreibzugriff (Freigabe nötig) |
| NAND | 256 MiB: config, kernel1/rootfs1 (Stock aktiv), kernel2/rootfs2 (Stock alt) `[DUMP]` | 10-MiB-Kernelslot reicht für einen Loader, nicht für ein OS |
| Netz | eth0 läuft, aber **≈0,8 MB/s** (10-ms-Polling, HIF-IRQ maskiert) `[HW]` | Vor jedem NAS- oder Mesh-Betrieb zu beheben (P0) |
| Uhr | Seit V576 korrekt `[HW]` (die Angabe „6× zu schnell“ war veraltet) | – |
| CPU-Kerne | Bisher läuft nur **ein** Kern (kein SMP) `[HW]` | P0: V584 (SMP) gebaut, Test ausstehend |
| SPI-NOR unter Linux | `insmod spi-nor` legt die NAS lahm `[HW]` | Barebox-Env ist aus Linux heraus nicht änderbar |
| Watchdog | Projektregel: aus | Für unbeaufsichtigten Betrieb braucht das fertige OS einen Watchdog (P0) |
| Debian armhf | Debian 13 „trixie“ unterstützt armhf | Die Zukunft von armhf nach trixie ist nicht gesichert und muss geprüft werden. Wir bauen das Image so, dass ein Basiswechsel möglich bleibt |

## 1. Leitprinzipien

1. **Unveränderliches Grundsystem, veränderliche Schichten darüber** (Bazzite-Modell).
2. **Jede Stufe hat einen Rückweg.** Kein Update und keine Installation ohne funktionierenden vorherigen Zustand.
3. **NAND und SPI werden genau einmal beschrieben** (Loader) und danach vom laufenden OS nicht mehr angefasst.
4. **Gleiches Image für Installation, Offline-Update und Online-Update.**
5. **Mesh ist eine Funktion, kein Zwang:** Ein einzelnes Gerät ist ein vollwertiges NAS.

## 2. Bootkette und Kernelschutz

```
Barebox (SPI, unverändert)
 └─ Env-Skript: [TFTP, nur Entwicklung] → NAND kernel2 = UNTRASH-LOADER → NAND kernel1 (Stock, Notfall)
     UNTRASH-LOADER  (Linux 6.6 + kleines initramfs, ~8 MiB, im NAND)
      ├─ USB-Stick mit gültigem, signiertem Untrash-Image?  → Installer / Offline-Update
      ├─ Systemplatte(n) da? → Slot A/B wählen (Boot-Zähler) → Kernel + Root-Hash prüfen → kexec
      └─ nichts Bootfähiges → Rescue-System (heutiges V583 + Dropbear) mit SSH im LAN
```

- **Der Loader ist der Vertrauensanker.** Er prüft die Signatur von Kernel, initrd und dm-verity-Root-Hash (Ed25519) gegen einen eingebauten öffentlichen Schlüssel und startet dann per `kexec`.
- **Root-Dateisystem:** erofs, nur lesbar, mit **dm-verity** geschützt. `/etc` liegt als Overlay darüber und wird bei Updates mit einem 3-Wege-Merge abgeglichen (wie bei ostree). `/var` ist persistent.
- Im laufenden OS sind die MTD-Partitionen nur lesbar (DT und Kernel-Config). Den Loader kann nur der Loader selbst aktualisieren.
- **Ehrliche Grenze:** Barebox prüft nichts, und wer physischen Zugriff oder UART hat, kann den Loader ersetzen. Der Schutz wirkt gegen Fehlbedienung, kaputte Updates und Manipulation aus dem laufenden System. Eine Hardware-Vertrauenskette wie Secure Boot entsteht dadurch nicht. Das entspricht etwa der Praxis bei Bazzite, die ebenfalls vor allem auf Atomizität und Rollback setzt.
- `kexec` auf C2K-SMP ist unerprobt. Rückfallebene: Der Loader-Kernel *ist* der Systemkernel und wechselt per `switch_root` auf die geprüfte Root. Kernel-Updates bräuchten dann einen NAND-Schreibvorgang durch den Loader. **[E-1]**
- **Testbarkeit:** Der Loader lässt sich vollständig per TFTP im RAM testen, bevor irgendetwas ins NAND geschrieben wird. Das ist derselbe Weg wie bei V583.

Alternative ohne NAND (Plan B): Barebox liest den Loader per `sata read` aus festen Sektoren der Platte in Bay 1. Das kommt ohne NAND-Schreibzugriff aus, hängt aber an Platte 0 und an festen LBA-Werten im Env. **[E-2]**

## 3. Systemimage und Paketmodell („wie Bazzite, aber Debian“)

| Bazzite / Fedora Atomic | UntrashOS `[PLAN]` |
|---|---|
| ostree-Image, read-only `/usr` | erofs + dm-verity, A/B-Slots, gebaut mit **mkosi** (reproduzierbar, Debian-fähig, unterstützt verity, sysext und sysupdate) |
| `rpm-ostree install` (Layering) | **`untrash pkg add <deb>`** erzeugt in einem passenden Debian-Builder-Container eine **systemd-sysext**-Erweiterung, signiert sie lokal und aktiviert sie. Nach einem Basis-Update wird sie automatisch neu gebaut |
| Flatpak | **Podman + Quadlet** (Apps als Container, App-Katalog im Web-Desktop). Achtung: Viele Container-Images gibt es nicht für `linux/arm/v7`. Der Katalog zeigt nur geprüfte Apps |
| toolbox / distrobox | Debian-„Werkbank“-Container mit `apt` für Bastler, ohne das Grundsystem zu verändern |
| Rollback im Bootmenü | Boot-Zähler im Loader, Rollback per Web-UI oder automatisch nach drei Fehlstarts |

Updates laufen über `systemd-sysupdate`: in den inaktiven Slot schreiben, prüfen, umschalten, bei Erfolg bestätigen (`boot-complete.target`).

## 4. Plattenlayout (jede Platte, GPT) `[PLAN]`

| Part. | Name | Größe | Inhalt |
|---|---|---|---|
| 1 | `ut-sys-a` | 1 GiB | md RAID1 (Metadata 1.0) über alle Platten: Kernel, erofs-Root, verity |
| 2 | `ut-sys-b` | 1 GiB | wie A |
| 3 | `ut-state` | 4 GiB | md RAID1, ext4: `/var`, `/etc`-Overlay, Konfigurationsdatenbank, Logs |
| 4 | `ut-swap` | 1 GiB | md RAID1, Swap |
| 5 | `ut-data` | Rest | Daten-RAID nach Wahl (0/1/5/6/10/JBOD), darauf **btrfs** (Snapshots, Prüfsummen, send/receive) |

Bei Metadata 1.0 liegen die RAID-Metadaten am Ende der Partition. Der Loader kann deshalb ein einzelnes Mitglied wie ein normales Dateisystem lesen, und jede Platte kann booten. btrfs läuft über md (Synology-Prinzip), nie mit dem btrfs-eigenen RAID5/6.

**32-bit-Grenze (gilt für jedes Dateisystem):** Ein 32-bit-Kernel kann pro Volume höchstens 16 TiB verwalten (Index des Seitencaches). ext4 und XFS lassen sich größer gar nicht einhängen. btrfs warnt ab 10 TiB und verweigert ab 16 TiB *logischer Adressen*; diese wachsen mit jedem `balance`, auch ohne mehr Daten. Folge: Volumes auf ≤ 16 TiB begrenzen (bei mehr Kapazität mehrere Volumes anlegen) und `balance` nur gezielt einsetzen.

## 4a. Übernahme vorhandener Datenträger (Kerneigenschaft, E-3)

**Anforderung (Operator, 2026-10-08):** UntrashOS versteht die Daten des alten Betriebssystems und stellt sie **genauso bereit wie zuvor**: gleiche Freigaben, gleiche Benutzer und Rechte, gleiche Pfade. Darüber hinaus werden alle gängigen vorhandenen Dateisysteme unterstützt.

**Grundsätze**
1. Fremde und alte Volumes werden **nie automatisch verändert**: kein fsck mit Reparatur, kein Upgrade der md- oder LVM-Metadaten, kein Ändern von Dateisystem-Features. Beim ersten Erkennen wird nur lesend eingehängt. Erst nach einer Bestätigung in der Web-UI wird schreibend übernommen.
2. **Übernahme ohne Umpartitionieren:** Auf Platten mit vorhandenen Daten legt der Installer die Systemslots A/B, `ut-state` und Swap als **Dateien** in `/.untrash/` auf dem vorhandenen Volume ab. Der Loader ist ein vollwertiger Linux-Kernel und kann sie über md, LVM und ext4 finden und einhängen. Das eigene Layout aus Abschnitt 4 gilt nur für leere Platten.
3. **Alte Pfade bleiben gültig:** z. B. `/i-data/<vol-id>` als Bind-Mount bzw. Symlink, damit vorhandene rsync-Jobs, Skripte und Backup-Ziele weiter funktionieren.
4. Eine Migration auf btrfs ist **optional und kopierbasiert** (nur bei genug freiem Platz). Ein In-place-`btrfs-convert` wird nicht angeboten.

**Stock-NAS542** – belegt 2026-10-09 in `stock-takeover.md` (Layout, Metadata 1.2 statt 1.0, Konfiguration im NAND-UBIFS `ubi_config`, DB-Schema, Rechte-Semantik, Importer). Ursprüngliche Annahmen:
- Speicherstapel: mdadm (RAID1 wird mit `--metadata=1.0` angelegt) → LVM2 (`vgcreate`/`lvcreate` vorhanden) → ext4
- Einhängepunkte `/i-data/<vol-id>` und `/i-data/sysvol`
- Konfiguration unter `/etc/zyxel/` (u. a. `conf/startup`, `storage/`, `ftp`, `webdav`) und `/etc/samba/smb.conf`
- USB-Dateisysteme: FAT, exFAT, NTFS (Tuxera `tntfs`), HFS/HFS+
- Offen: wo `/etc/zyxel` dauerhaft liegt (NAND `config` und/oder sysvol), das genaue Partitionslayout und das Format der Benutzer-, Freigabe- und Rechtedaten
- Importer `untrash import zyxel` übersetzt Benutzer und Gruppen (gleiche UIDs/GIDs, Samba-Passwort-Hashes falls übernehmbar, sonst Passwortänderung beim ersten Login), Freigaben, ACLs, Dienste (SMB, NFS, FTP, WebDAV) und Kontingente in die Untrash-Konfiguration

**Unterstützte Schichten (Kernel-Konfiguration ist Pflicht, mit Testmatrix)**

| Schicht | Unterstützung |
|---|---|
| RAID / Volume | md (Metadata 0.90/1.0/1.1/1.2, alle Level), LVM2 inkl. Thin, dm-crypt/LUKS1/2 |
| Linux-FS | ext2/3/4, btrfs, XFS, F2FS, JFS. ReiserFS ist nur in 6.6 noch vorhanden und wird nur lesend importiert |
| Wechseldatenträger | FAT/vFAT, exFAT (Kernel), NTFS (Kernel-`ntfs3`, lesen und schreiben), HFS+ (Kernel; mit Journal nur lesend), ISO9660/UDF |
| Andere NAS | Synology und QNAP (md + LVM + ext4/btrfs): Import mindestens lesend. Proprietäre Schichten (Synology-btrfs-Erweiterungen, QNAP-`cachedev`/Thin-Pools) sind im Einzelfall zu prüfen |
| Nicht unterstützt | ZFS (für 32-bit ungeeignet), APFS (nur optional über ein lesendes Fremdmodul). Import solcher Datenträger über einen anderen Rechner |

**Abnahmetest „Referenz-Altbestand“:** Die Stock-Firmware (NAND kernel1, Fallback im Env) legt auf der Testplatte ein Volume mit Freigaben, Benutzern und Rechten an. UntrashOS muss danach ohne Umpartitionieren booten und dieselben Freigaben mit denselben Rechten bereitstellen. Ein Windows- bzw. Linux-Client prüft das von außen. Der Stock-Boot ist ein Hardwarelauf und braucht eine eigene Freigabe.

## 5. Backup und Recovery (zuerst festzulegen)

**Ebene A – Plattform:** SPI- und NAND-Abzüge mit Hashes liegen vor (`re-1/.../mtd/`). Pflicht: zwei Kopien außerhalb der NAS und eine dokumentierte, getestete Wiederherstellung (PartnerKey/TFTP, UART als letzter Ausweg). Bevor der Installer den Loader schreibt, sichert er die betroffenen Bereiche erneut auf den Stick und prüft die Sicherung.

**Ebene B – Bootkette:** neuer Slot → alter Slot → Rescue-SSH im Loader → Stock-kernel1 → TFTP.

**Ebene C – Konfiguration:** Ein *Config-Bundle* (Benutzer, Freigaben, Dienste, Mesh-Identität, sysext-Liste, Container-Definitionen) wird nach jeder Änderung versioniert und liegt auf jeder Platte (`ut-state`), auf Wunsch auf USB und auf Mesh-Peers. Eine Neuinstallation mit Bundle stellt die NAS vollständig wieder her.

**Ebene D – Nutzdaten (Produktfunktionen):**
- btrfs-Snapshots pro Freigabe (Zeitplan und Aufbewahrung), auch für Windows unter „Vorgängerversionen“ (Samba `shadow_copy2`)
- Sicherungsjobs: auf USB (inkl. COPY-Taste), auf eine andere NAS oder einen Mesh-Knoten (btrfs send/receive bzw. rsync), offsite verschlüsselt mit **restic** (S3, B2, SFTP), Cloud-Sync mit rclone
- Ziel-Dienste: Time-Machine-Freigabe, rsync-Server, restic-REST-Server
- Assistent für die 3-2-1-Regel mit Ampelanzeige im Desktop

**Grundsatz:** Mesh-Redundanz ist **kein Backup**, denn Löschungen werden mitrepliziert. Nur Snapshots und getrennte Sicherungen schützen davor.

**Ebene E – Installationsschutz:** Der Installer überschreibt keine Platte mit erkennbaren Daten ohne ausdrückliche Bestätigung und sichert vorher Partitionstabellen und md-Superblöcke auf den Stick.

## 6. Installation per USB

**Befund:** Barebox kann kein USB `[DUMP]`. Ein Image „nur mit dem richtigen Dateinamen“ funktioniert deshalb nicht auf Barebox-Ebene. Auch das Stock-Firmware-Update prüft mehrere Checksummen (`core/zld/romfile/img_checksum_{1,2}` im Env) `[DUMP]`.

Es gibt zwei Wege, die beide die gewünschte Bedienung bieten (Stick rein, einschalten, Installation läuft):

**(a) NAS mit UntrashOS bzw. Loader.** Der Loader sucht bei jedem Start auf USB nach
```
UNTRASH/untrash-nas542-<version>.img      # Image
UNTRASH/untrash-nas542-<version>.img.sig  # Signatur (Pflicht, ein Name allein genügt nicht)
UNTRASH/install.toml                      # optional: Antwortdatei
```
`install.toml` enthält Modus (install | update | restore), Rolle (`master` | `slave` | `backup-master`), Mesh-Beitrittstoken, Hostname, Platten- und RAID-Richtlinie, Pfad zum Config-Bundle und `confirm = auto | button | web`.
Ohne `confirm = auto` auf leeren Platten wartet der Installer auf eine Bestätigung: COPY-Taste 5 s halten (LED-Rückmeldung) oder Klick im Mini-Web-Installer des Loaders. Ist bereits ein System installiert, macht derselbe Stick ein **Offline-Update** statt einer Neuinstallation.

**(b) Fremde NAS542/NAS5xx mit Stock-Firmware.** Die Stock-Firmware führt beim Start `usb_key_func.sh` von einem **PartnerKey**-Stick als root aus, wenn `nas5xx_check_file` gültig ist. Das Projekt hat diesen Weg im Juli 2026 erfolgreich genutzt `[HW]`. Ein PartnerKey-Installer würde Flash sichern, den Loader nach kernel2 und das Env schreiben und neu starten. Danach übernimmt Weg (a) mit demselben Stick. Damit lassen sich Mesh-Slaves ohne UART und ohne Aufschrauben vorbereiten. Offen: Herkunft und Weitergabe der Check-Datei (rechtlich und technisch) **[E-5]**.
Das Hochladen einer gefälschten Zyxel-Firmware über die Stock-Web-UI ist nur ein Forschungspunkt mit niedriger Priorität.

## 7. Web-Desktop

**Empfehlung:** **Cockpit** als Unterbau (PAM-Login, Rechteverwaltung, WebSocket/D-Bus-Bridge, socket-aktiviert und damit ohne Leerlauf-RAM). Vorhandene Module (Storage/udisks2, Netzwerk, Podman, Dateien, Logs, Terminal) werden direkt genutzt. Darauf kommt eine eigene Oberfläche **„Untrash Desk“** als Cockpit-Paket: ein Fenster-Desktop im Stil des Zyxel- bzw. DSM-Desktops. Jede „App“ ist ein Cockpit-Modul (Speicher-Manager, Freigaben, Backup, Mesh, App-Katalog, Paketverwaltung).
Begründung: Die Sicherheitsschicht (Auth, Privilegien) wird nicht selbst gebaut. Eigener Code steckt nur in der Oberfläche und den NAS-spezifischen Modulen.
**Gestaltung:** Design-System, Untrash-Desk-Vorschau und Asset-Pipeline in `untrash-design.md` (`os/design/`).
Verworfen: OpenMediaVault (verwaltet das System per apt/Salt, verträgt sich nicht mit einem unveränderlichen Root). Ein komplett eigenes Backend wäre deutlich mehr Arbeit und Angriffsfläche.

## 8. Funktionsumfang NAS542 → UntrashOS

Checkliste ableiten aus der Stock-Web-UI (`private/boot-discovery/sysdisk-analysis/rootfs/usr/local/apache/htdocs/desktop,/script/*.js`). Vorläufig:

| Stock-Funktion | UntrashOS |
|---|---|
| RAID 0/1/5/6/10/JBOD, Hot-Spare, Erweitern/Migrieren | mdadm + btrfs, Assistent im Speicher-Manager |
| Plattengesundheit, Spin-down | smartd, hd-idle, Benachrichtigung |
| Benutzer, Gruppen, Quotas, ACLs | lokal oder mesh-weit (Abschnitt 9), btrfs-qgroups |
| SMB, AFP/Time Machine, NFS, FTP, WebDAV | Samba (inkl. `vfs_fruit` statt AFP), nfs-kernel-server, vsftpd, WebDAV, SFTP |
| DLNA, iTunes-Server, Fotos | ReadyMedia, OwnTone, Foto-App als Container |
| Download-Service | Transmission/aria2 (Container) |
| Backup Planner, USB Copy/Sync-Taste | Abschnitt 5 (COPY-Taste ist bereits als Input-Event vorhanden) |
| Energie: Zeitpläne, Lüfter, LEDs, Buzzer, USV | zt-fan, LED-Trigger, NUT. RTC-Weckfunktion und Wake-on-LAN sind zu prüfen |
| Zweiter LAN-Port, Link Aggregation | eth0 und eth1 laufen mit dem Vendor-PFE-Treiber (V586, je 1 Gbit/s); bond0 über systemd-networkd (Stand 2026-10-10, Bonding auf Hardware noch nicht getestet) |
| myZyXELcloud | entfällt; Ersatz: WireGuard-Fernzugriff + Mesh |
| Firmware-Update | A/B-Image-Update (Abschnitt 3/6) |

## 9. UntrashMesh

### Ziel
Mehrere NAS (NAS5xx, SoC-gleiche Geräte wie QNAP mit Comcerto 2000) erscheinen als **ein** Speicher mit einer Verwaltung. Ein Master steuert, die übrigen Knoten treten als Slaves bei, optional gibt es einen Backup-Master.

### Kernentscheidung: kein RAID auf Blockebene über das Netz
Ein md-RAID über NBD oder iSCSI zwischen NAS-Geräten wird verworfen. Jeder Neustart und jede Netzstörung eines Knotens degradiert das ganze Array. Darauf folgt ein voller Resync über GbE, bei Split-Brain drohen Datenverluste, und der Master ist ein Single Point of Failure. Diese Nachteile ließen sich nicht „sofort beheben“, sie stecken im Prinzip.

### Vorgeschlagen: zwei Speicherklassen pro Freigabe
1. **Lokal (Föderation, Standard):** Jeder Knoten hat sein eigenes RAID. Der Master bietet einen gemeinsamen Namensraum (eine Freigabe-Liste und SMB-DFS-Verweise bzw. NFS-Referrals auf den Knoten, der die Daten hält). Das ist robust und einfach, bringt aber keine Redundanz über Knoten hinweg.
2. **Mesh-redundant (verteilt):** Für Freigaben, die einen Knotenausfall überstehen sollen. Daten werden pro Datei bzw. Chunk mit wählbarer Kopienzahl oder Erasure Coding verteilt. So entsteht der „geteilte RAID“ ohne die Nachteile von Blockgeräten: Rebuilds betreffen nur fehlende Chunks, unterschiedlich große Platten werden voll genutzt, Knoten können kommen und gehen.
   Kandidaten für einen Vergleichs-Spike mit 2–3 Knoten:
   - **SeaweedFS:** Go, armv7-Builds, Master-HA per Raft, EC, FUSE/S3/WebDAV
   - **MooseFS CE:** POSIX, „goals“ pro Verzeichnis, Metalogger. Automatischer Master-Failover gibt es nur in der Pro-Version
   - (Garage nur S3, gut als Backup-Ziel; Ceph scheidet wegen RAM/armhf aus; GlusterFS wegen schwacher Wartungslage nur als Notlösung)

### Rollen
| Rolle | Aufgabe |
|---|---|
| `master` | Steuerung: Desktop, Benutzer, Freigabe-Konfiguration, Mesh-Metadaten, Update-Orchestrierung |
| `backup-master` | Hält eine laufende Replik der Steuerdaten (Config-DB, Metadaten-Server) und übernimmt bei Ausfall |
| `slave` | Speicher- und Dienstknoten, verwaltet vom Master |
| `witness` (neu) | Stimmt nur ab: winziger Dienst, z. B. auf einem Slave, einem Raspberry Pi oder als Container auf dem PC |

**Wichtig für den Backup-Master:** Eine automatische Übernahme ist nur mit **Quorum (≥ 3 Stimmen)** sicher. Mit genau zwei Geräten kann keines unterscheiden, ob der andere ausgefallen ist oder nur das Netz. Ohne dritte Stimme droht Split-Brain. Darum gilt: 2 Knoten → Übernahme per Knopfdruck. Ab 3 Knoten bzw. mit Witness → automatisch. **[E-6]**

### Verbindung und Sicherheit
Der Beitritt läuft über ein Token aus `install.toml` oder aus der Web-UI. Jeder Knoten erhält eine Identität (Schlüsselpaar), die Steuerung läuft über mTLS. Datenverkehr im LAN ist optional unverschlüsselt (CPU-Budget des A9), über Standorte hinweg geht er per WireGuard. Benutzer und Gruppen verwaltet der Master zentral (einheitliche UIDs auf allen Knoten, sonst passen die SMB-Rechte nicht). Die Zeit synchronisiert chrony.

### Bekannte Nachteile und Gegenmaßnahmen
| Nachteil | Gegenmaßnahme |
|---|---|
| Netz ist der Engpass (heute 0,8 MB/s) | P0: PFE-IRQ-Betrieb. Mesh-redundante Freigaben erst ab gemessenem Durchsatz freigeben |
| Versionsunterschiede zwischen Knoten | Versioniertes Mesh-Protokoll, rollierende Updates durch den Master, Knoten mit Version N±1 bleiben kompatibel |
| Rebuild-Last | Drosselbare Rebuilds, Priorität auf Nutzer-I/O |
| Fremdgeräte (QNAP C2K) | Der Mesh-Agent ist hardwareunabhängig (armhf/arm64/x86 mit Debian). Jede neue Hardware braucht trotzdem einen eigenen Board-Port (Bootloader, DT, Treiber), das ist eine eigene Projektspur |
| Master-Ausfall | Backup-Master + Witness. Datenzugriff auf lokale Freigaben läuft ohne Master weiter |

## 10. Phasen

| Phase | Inhalt | Hardware/Flash |
|---|---|---|
| **P0** Plattform | SMP (V584), PFE-Durchsatz (Vendor-Treiber-Port), Watchdog, `mem=` auf vollen RAM, UART-freie Blackbox. Plan: `reports/P0-PLATFORM-PLAN.md` | RAM-Boots |
| **P1** Fundament (Plan: `docs/recovery/p1-platform-backup-and-loader.md`) | Backup-Ebenen A–E dokumentiert und getestet. Loader bauen und per TFTP im RAM testen. Stock-Speicherlayout und Konfigurationsformat belegen (4a), Referenz-Altbestand anlegen | RAM-Boots, Stock-Boot |
| **P2** Image | mkosi-Build Debian 13 armhf, erofs+verity, sysupdate. Übernahme-Installation auf dem Referenz-Altbestand und Neuinstallation auf leerer Platte, Start über den TFTP-Loader | Plattenschreiben (Freigabe) |
| **P3** Eigenständig | Loader nach NAND kernel2 und Env-Reihenfolge anpassen, USB-Installer/-Update | **Flash-Schreiben (separate Freigabe)** |
| **P4** NAS-Funktionen | Cockpit + Untrash Desk, Freigaben, Backup-App, App-Katalog, `untrash pkg` | – |
| **P5** Mesh | Spike SeaweedFS vs. MooseFS, Rollen, Witness, Föderation | zweites Gerät |
| **P6** Verbreitung | PartnerKey-Installer für Stock-Geräte, Board-Ports weiterer Geräte | – |

## 11. Offene Entscheidungen

- **[E-1] entschieden 2026-10-08:** Kernelwechsel per kexec (auf Hardware bewiesen, V588)
- **[E-2] entschieden 2026-10-08:** Loader im NAND kernel2
- **[E-3] entschieden 2026-10-08:** Neue Volumes: btrfs auf md (Standard), ext4 als Option. Zusätzlich gilt die Kerneigenschaft „Übernahme vorhandener Datenträger“ (Abschnitt 4a)
- **[E-4] entschieden 2026-10-08:** Cockpit + eigene Desk-Oberfläche „Untrash Desk“
- **[E-5]** PartnerKey-Installer für Stock-Geräte verfolgen (Herkunft der Check-Datei klären)
- **[E-6]** Failover mit Witness automatisch, bei 2 Knoten manuell (Empfehlung)
- **[E-7]** Verteilte Schicht: Spike SeaweedFS vs. MooseFS
- **[E-8] entschieden 2026-10-08:** Die 2-TB-Platte in Bay 1 darf für P2 vollständig neu partitioniert werden. Jeder Schreiblauf braucht trotzdem eine eigene Freigabe
