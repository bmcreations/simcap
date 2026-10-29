# simcap: the iOS simulator and iPhone helper loupe runs from .build/simcap.
# xcrun swiftc, not the swiftc on PATH, which does not match the SDK.
# CoreDeviceMediaStreamSupport, which -phone-wifi negotiates through, ships
# nested inside CoreDevice.framework.
CDMS_DIR := /Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks
SRC := main.swift input.swift ax.swift hub.swift pasteboard.swift displays.swift devices.swift \
	encoder.swift phone.swift phoneinput.swift wifi.swift hostpasteboard.swift

.PHONY: simcap clean

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

clean:
	rm -rf .build
