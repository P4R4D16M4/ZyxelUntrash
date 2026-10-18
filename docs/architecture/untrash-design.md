# UntrashOS – Design-System

Stand 2026-10-09. Bezug: `untrash-os-concept.md` §7 (Web-Desktop „Untrash Desk“ auf Cockpit).

Grundlage sind die drei Vorlagen des Betreibers im Projektwurzelverzeichnis: `untrashlogo.png`, `untrash icons.png`
und `untrashwallpaper.png`. Alles, was diese Vorlagen nicht zeigen (Leisten, Fenster, Popups, Dialoge, Formulare,
Anmeldung, Installer), ist daraus abgeleitet.

## Dateien

| Datei | Zweck |
|---|---|
| `os/design/untrash.css` | **Einzige Quelle** für Tokens und Bausteine (Präfix `ut-`). Gilt für den Installer, Untrash Desk, die Anmeldung und später das Cockpit-Branding |
| `os/design/mk-assets.py` | Schneidet die Vorlagen reproduzierbar zu Web-Assets: 12 Icons (256/128/64 px, runde Maske), Logo, Bildmarke, Wortmarke, Favicon (Farbe-zu-Alpha gegen den Hintergrund `#0d1015`) und Wallpaper (voll, 960 px, unscharf) |
| `os/design/assets/icons/{mesh,packages,logs,settings}.svg` | Ergänzte App-Icons im Stil des Sets (UntrashMesh, Pakete, Protokolle, Einstellungen) |
| `os/design/desk.html` | Klickbare Vorschau des Untrash Desk: Topbar, Desktop-Icons, Dock, ziehbare Fenster, Launcher, Kontextmenü, Benachrichtigungen, Dialoge |
| `os/design/login.html` | Anmeldebildschirm |
| `os/design/styleguide.html` | Übersicht aller Bausteine |

Vorschau am PC: `python3 -m http.server 8765 --directory os/design` → `http://localhost:8765/desk.html`
(oder Konfiguration `untrash-design` in `.claude/launch.json`).

Im Image: `os/image/mkslot-erofs.sh` kopiert CSS und eine Teilmenge der Assets (rund 680 KB) nach
`/usr/share/untrash/design/`. Der Installer liefert sie unter `/ut/…` aus: nur aus diesem Verzeichnis, nur `.css`, `.png`,
`.svg`, `.jpg` und `.ico`, mit `realpath`-Prüfung gegen Pfad-Traversal. Fehlt das Verzeichnis, bleibt die Seite
bedienbar, weil sie eine kleine Inline-Rückfallgestaltung mitbringt.

## Grundsätze

1. **Nur dunkel.** Die Marke hat keine helle Variante; `color-scheme: dark`.
2. **Offline und leicht.** Keine Web-Fonts, keine externen Abrufe, kein Framework. Systemschrift (`system-ui`), Monospace
   für Geräte, Pfade und Protokolle. Die NAS ist oft offline, und der A9 soll wenig parsen.
3. **Akzent sparsam.** Der Verlauf Grün → Türkis → Cyan markiert nur Primäraktion, Fortschritt, aktive Auswahl und das
   fokussierte Fenster. Alles andere bleibt neutral blaugrau.
4. **Fremde Daten sind sichtbar geschützt.** Fremde und Stock-Volumes zeigen immer `Nur lesen` (Warnfarbe), bis die
   Übernahme bestätigt ist (Kernforderung aus dem Konzept §4a). Zerstörende Wege (Weg A, Löschen) sind rot, und der
   Bestätigungsknopf ist dann `ut-btn--danger` statt primär.
5. **Zustände tragen Text, nicht nur Farbe** (Pill mit Punkt und Wort).

## Tokens (Auszug, vollständig in `untrash.css`)

| Gruppe | Werte |
|---|---|
| Flächen | `--ut-bg-0` `#080b0e` (Desktop) · `-1` `#0d1115` (Fenster) · `-2` `#12171c` (Karten, Seitenleisten) · `-3` `#181e24` (Kacheln, Felder) · `-4` `#202830` (Hover) · `-5` `#2a333c` (gedrückt) |
| Glas | `--ut-glass` `rgba(13,17,21,.72)` + `backdrop-filter: blur` für Topbar, Dock, Menüs, Toasts |
| Linien | Weiß mit 7 / 12 / 20 % Deckkraft |
| Text | `#e9eef2` · `#aab4bd` · `#6f7b86` |
| Marke (gemessen im Logo) | Lime `#98f56c` · Grün `#5def6b` · Türkis `#05c7af` (das „OS“) · Cyan `#00c8c9` · Tiefcyan `#00a9bc` |
| Verlauf | `--ut-grad` `120deg, #6ff06b → #19d6a6 → #00bfd0`; Text darauf `#04170f` |
| Zustände | ok `#5def6b` · info `#00c8c9` · warn `#f4b54a` · danger `#ff5f6d` (je mit 12–13 % Hintergrund) |
| Radien | 4 / 7 / 10 / 14 / 20 px; App-Kacheln 19 % der Kantenlänge wie im Icon-Set |
| Schatten | tief und weich (`--ut-sh-3` für Fenster und Popups) plus 1 px Oberkanten-Licht `--ut-hl` wie bei den Kacheln |
| Schrift | 14 px Grundgröße im Desk, 12 / 13 / 16 / 20 / 28 px |

## Bausteine

| Baustein | Klassen | Hinweise |
|---|---|---|
| Topbar | `ut-topbar`, `__item`, `__title`, `__badge` | 34 px, Glas, links Bildmarke + Launcher, Mitte der Titel der aktiven App, rechts Tray (RAID-Zustand, Netz, Glocke, Benutzer, Uhr). Darunter eine Marken-Haarlinie, die nach rechts ausläuft |
| Dock | `ut-dock`, `__item`, `__sep` | unten mittig, Glas, 48 px-Kacheln aus dem Icon-Set; Strich unter dem Icon: kurz = läuft, lang mit Glühen = aktiv. Ausschalten steht immer rechts hinter dem Trenner |
| Desktop-Icons | `ut-desktop-icons`, `ut-desk-icon` | Spaltenraster links, Auswahl türkis umrandet, Doppelklick öffnet |
| Fenster | `ut-window`, `__bar`, `__title`, `__ctl`, `__body`, `__main`, `__foot` | Titelleiste 40 px mit App-Icon; das fokussierte Fenster hat oben eine 2 px-Verlaufslinie und einen türkisen Rand. Schließen färbt sich beim Hover rot |
| App-Navigation | `ut-sidebar`, `ut-nav[aria-current]`, `ut-tabs`/`ut-tab` | aktive Seite: weicher Verlaufshintergrund + Verlaufsbalken links |
| Launcher | `ut-menu ut-launcher` | App-Raster mit Suche, öffnet über die Bildmarke |
| Menü / Kontextmenü | `ut-menu`, `__item`, `__item--danger`, `__sep`, `__label` | |
| Benachrichtigung | `ut-toasts` > `ut-toast(--warn/--danger)` | oben rechts unter der Topbar, App-Icon links, farbiger Balken links, optional Aktionen |
| Dialog | `ut-scrim` > `ut-dialog(--danger/--warn)` | Hintergrund abgedunkelt und unscharf; Icon-Plakette links; Fußzeile mit Abbrechen + Aktion |
| Formulare | `ut-field`, `ut-input`, `ut-select`, `ut-switch`, `ut-choice` | `ut-choice` ist die große Auswahlkarte mit Buchstaben-Plakette (Installer-Wege, RAID-Level) |
| Daten | `ut-table(-wrap)`, `ut-pill--ok/info/warn/danger/live`, `ut-progress(--warn/--indeterminate)`, `ut-stat`, `ut-steps`, `ut-log`, `ut-callout--*` | |
| Seiten ohne Desk | `ut-page`, `__head`, `__main` | Installer und Recovery: Kopfzeile mit Marke, 880 px Inhalt |
| Anmeldung | `ut-login`, `__card`, `__logo`, `__word` | unscharfes Wallpaper, Glaskarte, Bildmarke + Wortmarke, Hostname |

App-Icons: `files`, `shares`, `storage`, `raid`, `network`, `users`, `updates`, `backup`, `terminal`, `apps`, `monitor`,
`power` (PNG) sowie `mesh`, `packages`, `logs`, `settings` (SVG). Neue Icons folgen dem SVG-Muster: dunkle Kachel mit
`rx=48` auf 256, grauer Körper mit Verlauf `#6a737d → #3a4249`, Akzent im Markenverlauf, weicher Schlagschatten.

## Umsetzung

- **Installer (erledigt 2026-10-09):** `untrash-installer` nutzt `untrash.css`. Die Wege sind Auswahlkarten (B und C
  zuerst, A rot), der Plan erscheint als `ut-steps`, die Bestätigung als Warn- oder Gefahrenhinweis, der Ablauf mit
  Status-Pill und `ut-log`. API und IDs sind unverändert. Geprüft im Browser mit einer Attrappe für `scan`/`plan`
  (Desktop und 375 px). Auf der NAS erst mit dem nächsten Slot-Build.
- **Untrash Desk (P4):** Cockpit-Paket. `desk.html` ist die Vorlage für die Shell; jede App ist ein Cockpit-Modul, das
  `untrash.css` lädt und `ut-window__main` als Wurzel nutzt.
- **Cockpit-Branding (P4, offen):** `/usr/share/cockpit/branding/<ID>/` mit `branding.css` (Login über `ut-login`-Werte),
  `logo.png` = `logo-mark-192.png`, `favicon.ico`, `bg-plain.jpg` = `wallpaper-blur.jpg`. Cockpit wählt das
  Verzeichnis über `ID`/`VARIANT_ID` aus `/etc/os-release`; das Image muss dafür `VARIANT_ID=untrash` setzen.
- **Offen:** Die Vorlagen (`untrash*.png`) und die erzeugten Assets sind noch nicht versioniert. Für reproduzierbare
  Builds müssen mindestens die Vorlagen oder `os/design/assets/` eingecheckt werden.
