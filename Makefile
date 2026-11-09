# simcap: the iOS simulator and iPhone helper loupe runs from .build/simcap.
# xcrun swiftc, not the swiftc on PATH, which does not match the SDK.
# CoreDeviceMediaStreamSupport, which -phone-wifi negotiates through, ships
# nested inside CoreDevice.framework.
CDMS_DIR := /Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks
SRC := main.swift input.swift ax.swift hub.swift orientation.swift pasteboard.swift displays.swift devices.swift \
	encoder.swift phone.swift phoneinput.swift phoneax.swift wifi.swift rtp.swift hostpasteboard.swift panels.swift sps.swift

.PHONY: simcap clean test

# Signed by TEAM when given, so TCC's camera grant for a phone's screen
# capture survives a rebuild (sign.sh).
simcap:
	mkdir -p .build/coredevice
	xcrun swiftc -emit-module -enable-library-evolution -parse-as-library -module-name CoreDevice \
		coredevice/CoreDevice.swift -o .build/coredevice/CoreDevice.swiftmodule
	xcrun swiftc -emit-module -enable-library-evolution -parse-as-library -module-name CoreDeviceMediaStreamSupport \
		-I .build/coredevice coredevice/CoreDeviceMediaStreamSupport.swift \
		-o .build/coredevice/CoreDeviceMediaStreamSupport.swiftmodule
	xcrun swiftc -O -I .build/coredevice $(SRC) -o .build/simcap \
		-framework VideoToolbox -framework CoreMedia -framework AppKit -framework CoreVideo -framework IOSurface -framework AVFoundation -framework CoreMediaIO \
		-F /Library/Developer/PrivateFrameworks -F $(CDMS_DIR) \
		-Xlinker -weak_framework -Xlinker CoreDevice -Xlinker -weak_framework -Xlinker CoreDeviceUtilities \
		-Xlinker -weak_framework -Xlinker CoreDeviceMediaStreamSupport \
		-Xlinker -rpath -Xlinker /Library/Developer/PrivateFrameworks -Xlinker -rpath -Xlinker $(CDMS_DIR) \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker res/Info.plist
	@if [ -n "$(TEAM)" ]; then ./sign.sh $(TEAM) .build/simcap; \
	else echo "simcap: signed ad hoc; each rebuild asks for the phone's camera again (make simcap TEAM=<team id> keeps the grant)"; fi

# simcap-bridge: the Rust helper that reads a cabled iPhone's accessibility
# tree over its own CoreDevice tunnel, since CoreDevice refuses its
# remoteAXService to simcap. Built with cargo into .build/simcap-bridge, beside
# simcap, where loupe looks for it. Needs Rust; simulator use does not, so this
# is a separate target the simcap build does not depend on.
#
# Ad hoc signed here. Shipping in a notarized dmg needs it signed with the
# hardened runtime under TEAM (its own identifier, not simcap's) -- not wired
# yet.
.PHONY: bridge
bridge:
	cargo build --release --manifest-path bridge/Cargo.toml
	mkdir -p .build
	cp bridge/target/release/simcap-bridge .build/simcap-bridge

# test: the Wi-Fi depacketiser (rtp.swift) against RTP streams the tests
# build, no phone needed, and a foldable's surface choice (panels.swift).
test:
	mkdir -p .build
	xcrun swiftc -parse-as-library rtp.swift tests/rtp_tests.swift -o .build/rtp_tests
	.build/rtp_tests
	xcrun swiftc -parse-as-library panels.swift tests/panels_tests.swift -o .build/panels_tests
	.build/panels_tests
	xcrun swiftc -parse-as-library sps.swift tests/sps_tests.swift -o .build/sps_tests
	.build/sps_tests

clean:
	rm -rf .build
