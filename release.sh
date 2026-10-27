#!/bin/sh
# release.sh TEAM [PROFILE]: build simcap, sign it with TEAM's Developer ID
# Application identity under the hardened runtime, notarize it with the
# notarytool keychain profile PROFILE (default loupe-notary), and write
# .build/simcap-macos.zip for loupe's releases page.
#
# A bare binary can't be stapled, so Gatekeeper checks the ticket online.
# The designated requirement names the identifier and team, not the leaf
# certificate, so a viewer's camera grant survives new releases and renewed
# certificates.
set -eu
team=$1 profile=${2:-loupe-notary}
make simcap
sha=$(security find-identity -v -p codesigning |
	awk -v t="Developer ID Application: .*($team)" '$0 ~ t { print $2; exit }')
if [ -z "$sha" ]; then
	echo "release.sh: no valid Developer ID Application identity for team $team" >&2
	exit 2
fi
id=dev.bmcreations.loupe.simcap
req="designated => identifier \"$id\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
codesign --force --sign "$sha" --identifier "$id" -r="$req" \
	--options runtime --timestamp --entitlements release.entitlements .build/simcap
codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" .build/simcap
rm -rf .build/release && mkdir -p .build/release
cp .build/simcap .build/release/simcap
rm -f .build/simcap-macos.zip
ditto -c -k .build/release .build/simcap-macos.zip
xcrun notarytool submit .build/simcap-macos.zip --keychain-profile "$profile" --wait
spctl -a -vv -t install .build/release/simcap 2>&1 || true
echo "release.sh: .build/simcap-macos.zip"
