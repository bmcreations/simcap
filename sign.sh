#!/bin/sh
# sign.sh TEAM BINARY: sign simcap with a valid Apple Development identity
# whose certificate's OU is TEAM.
#
# Ad hoc, simcap's designated requirement is its cdhash, so every rebuild is
# a new program to TCC: the phone's camera grant no longer matches, and
# -phone waits on a prompt on the Mac. Signed by a team, the requirement is
# the identifier and the team, which a rebuild keeps.
set -eu
team=$1 bin=$2
valid=$(security find-identity -v -p codesigning | awk '{print $2}')
sha=$(security find-certificate -a -Z -p -c "Apple Development" | awk -v team="$team" '
	/^SHA-1 hash:/ { h = $3; next }
	/BEGIN CERTIFICATE/ { pem = "" }
	{ pem = pem $0 "\n" }
	/END CERTIFICATE/ {
		fflush(); cmd = "openssl x509 -noout -subject 2>/dev/null"
		printf "%s", pem | cmd; close(cmd)
		# openssl prints to our stdout; mark the hash for the shell to pair.
		print "HASH " h; fflush()
	}' | awk -v team="$team" '/^subject=/ { ok = index($0, "OU=" team ",") > 0 } /^HASH / { if (ok) print $2; ok = 0 }' |
	while read -r h; do echo "$valid" | grep -qx "$h" && echo "$h"; done | head -1)
if [ -z "$sha" ]; then
	echo "sign.sh: no valid Apple Development identity for team $team" >&2
	exit 2
fi
codesign --force --sign "$sha" --identifier dev.bmcreations.loupe.simcap "$bin"
codesign -dr - "$bin" 2>&1 | grep designated
