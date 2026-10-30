# simcap

The macOS helper [loupe](https://github.com/bmcreations/loupe) runs to stream
and drive iOS simulators and physical iPhones. loupe starts it as a child
process and talks to it over stdin and stdout; it isn't meant to be run by
hand, though it can be.

simcap writes video in scrcpy's video wire format, so loupe reads an iOS
screen with the same parser it uses for an Android device. Frames are encoded
with VideoToolbox.

```
simcap <udid> [-bitrate bps] [-fps n]   stream a simulator
simcap <udid> -input                    inject a simulator's input
simcap <udid> -pasteboard               print a simulator's pasteboard on each change
simcap -hostpasteboard                  mirror this Mac's pasteboard
simcap -devices                         list physical iPhones and their HID capabilities
simcap <udid> -phone [name]             stream a physical iPhone on a cable
simcap <identifier> -phone-input        a physical iPhone's input
simcap <identifier> -phone-wifi [name]  stream a physical iPhone over Wi-Fi
simcap -caps                            print what this build can do
```

Each mode is documented at the top of its source file. loupe's
[docs/ios.md](https://github.com/bmcreations/loupe/blob/main/docs/ios.md)
covers how the server uses them.

## Private frameworks

simcap calls frameworks that Apple ships with Xcode but doesn't document or
support: CoreSimulator, SimulatorKit and AccessibilityPlatformTranslation for
simulators, and CoreDevice and CoreDeviceMediaStreamSupport for physical
phones. They load from your own Xcode install. An Xcode update can change them
and break simcap until it is fixed here.

## Building

You need Xcode; the build uses `xcrun swiftc`.

```sh
make simcap               # writes .build/simcap, signed ad hoc
make simcap TEAM=<team>   # signs it with your Apple Development identity for that team
```

An ad hoc signature is enough for simulators. Streaming a phone needs camera
access, and macOS ties that grant to the signature, so an ad hoc build asks
again after every rebuild. Building with `TEAM` keeps the grant.

To use your build, copy `.build/simcap` to loupe's `.build/simcap`, or start
loupe with `-simcap <path>`. `release.sh` builds the signed, notarized zip
attached to loupe's releases.

## License

Apache 2.0. See [LICENSE](LICENSE).

iPhone, Mac, macOS and Xcode are trademarks of Apple Inc. simcap is not
affiliated with Apple.
