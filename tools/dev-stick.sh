#!/usr/bin/env bash
# Turn an UntrashOS stick into a dev stick (docs/development/dev-stick.md):
# add SSH public keys to UNTRASH/ssh/authorized_keys.  With the stick plugged
# in at boot, the installed system lets these keys log in as root
# (untrash-servicekey).  For development NAS only, never for a user's stick.
#
#   tools/dev-stick.sh MOUNTPOINT [PUBKEY_FILE ...]   add keys (default ~/.ssh/id_ed25519.pub)
#   tools/dev-stick.sh MOUNTPOINT --list              show the keys on the stick
#
# Keys already on the stick are kept; a key is added once.  Only plain public
# key lines are accepted, the same format untrash-servicekey takes.
set -euo pipefail
M=${1:?usage: tools/dev-stick.sh MOUNTPOINT [PUBKEY_FILE ...] | --list}
shift
[ -d "$M/UNTRASH" ] || { echo "$M has no UNTRASH/: not an UntrashOS stick" >&2; exit 1; }
K=$M/UNTRASH/ssh/authorized_keys
RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+( [^ ]*)?$'
list() { [ -s "$K" ] && awk '{print NR": "$1" "substr($2,1,16)"... "$3}' "$K" || echo "no keys on the stick"; }
if [ "${1:-}" = --list ]; then list; exit 0; fi
[ $# -gt 0 ] || set -- "$HOME/.ssh/id_ed25519.pub"
mkdir -p "$M/UNTRASH/ssh"
touch "$K"
for f in "$@"; do
	while IFS= read -r line; do
		line=${line%$'\r'}
		[ -n "$line" ] || continue
		grep -Eq "$RE" <<<"$line" || { echo "$f: not a plain public key line, skipped" >&2; continue; }
		key=$(cut -d' ' -f1,2 <<<"$line")
		if grep -qF "$key" "$K"; then echo "already on the stick: ${line:0:40}..."
		else echo "$line" >>"$K"; echo "added: ${line:0:40}..."; fi
	done <"$f"
done
sync
list
