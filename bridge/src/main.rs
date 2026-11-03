// simcap-bridge <udid> [--follow]
//
// Opens the phone's accessibility tree service over idevice's CoreDevice
// tunnel and streams the raw tree-dump archives to stdout, one per DTX
// processDataFromRemoteDevice: message. Each frame is a little-endian u32
// length followed by that many bytes -- the archive exactly as the phone sent
// it (an NSKeyedArchiver archive whose root is an NSData wrapping the real
// AXPTranslatorResponse). loupe decodes it (internal/target/iosdeviceax.go);
// the bridge stays dumb on purpose.
//
// Default is one-shot: stream every archive that arrives, then exit once the
// phone goes quiet (the InitialDump + AdditionalData pair has landed) or the
// cap is hit. --follow keeps streaming until killed, for a live tree.
//
// Why Rust and not simcap: remoted refuses
// com.apple.accessibility.axAuditDaemon.remoteAXService to CoreDeviceService
// ("Client lacks privilege"), so simcap's createServiceSocket never opens it.
// idevice builds its own tunnel and reaches the service. See loupe docs/ios.md.

use idevice::{
    core_device_proxy::CoreDeviceProxy,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, UsbmuxdProvider},
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
    Idevice, IdeviceError, IdeviceService,
};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};
use std::{future::Future, pin::Pin};

const AX_SERVICE: &str = "com.apple.accessibility.axAuditDaemon.remoteAXService";
// How long to wait for the next archive before deciding the phone is done
// (one-shot fallback) and the overall ceiling on a single run.
const QUIET_AFTER: Duration = Duration::from_secs(3);
const HARD_CAP: Duration = Duration::from_secs(20);

// The phone pushes an InitialDump (geometry + labels), then an AdditionalData
// dump (adds roles), then unasked re-sends and an orientation message. These
// ASCII markers sit in the archive's $objects. A tree dump carries one of
// them; the orientation message carries neither. Scanning for them keeps the
// bridge dumb -- no plist parsing -- while filtering non-tree frames and giving
// one-shot a correct stop point (the first AdditionalData), not a guessed timer.
const MARK_INITIAL: &[u8] = b"AXPTreeDumpTypeInitialDump";
const MARK_ADDITIONAL: &[u8] = b"AXPTreeDumpTypeAdditionalData";

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    needle.len() <= hay.len() && hay.windows(needle.len()).any(|w| w == needle)
}

/// usbmuxd for the socket, the pair record read straight from usbmuxd:
/// idevice's own get_pair_record over usbmuxd hangs.
#[derive(Debug)]
struct Cable {
    usb: UsbmuxdProvider,
    pf: PairingFile,
}
impl IdeviceProvider for Cable {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        self.usb.connect(port)
    }
    fn label(&self) -> &str {
        "simcap-bridge"
    }
    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        let pf = self.pf.clone();
        Box::pin(async move { Ok(pf) })
    }
}

/// usbmuxd ReadPairRecord: connect the control socket, ask for the device's
/// pair record, and return the PairRecordData blob (itself a plist that
/// PairingFile parses). Ported from the spike's readpair.py because idevice's
/// get_pair_record hangs on this host.
fn read_pair_record(udid: &str) -> std::io::Result<Vec<u8>> {
    let mut s = UnixStream::connect("/var/run/usbmuxd")?;
    let mut dict = plist::Dictionary::new();
    dict.insert("MessageType".into(), "ReadPairRecord".into());
    dict.insert("PairRecordID".into(), udid.into());
    dict.insert("ClientVersionString".into(), "simcap-bridge".into());
    dict.insert("ProgName".into(), "simcap-bridge".into());
    let mut body = Vec::new();
    plist::to_writer_xml(&mut body, &plist::Value::Dictionary(dict))
        .map_err(|e| std::io::Error::other(e))?;

    let total = (16 + body.len()) as u32;
    let mut hdr = Vec::with_capacity(16);
    hdr.extend_from_slice(&total.to_le_bytes()); // length, incl. header
    hdr.extend_from_slice(&1u32.to_le_bytes()); // protocol version
    hdr.extend_from_slice(&8u32.to_le_bytes()); // message type: plist
    hdr.extend_from_slice(&1u32.to_le_bytes()); // tag
    s.write_all(&hdr)?;
    s.write_all(&body)?;

    let mut rh = [0u8; 16];
    s.read_exact(&mut rh)?;
    let len = u32::from_le_bytes([rh[0], rh[1], rh[2], rh[3]]) as usize;
    if len < 16 {
        return Err(std::io::Error::other("short usbmuxd reply"));
    }
    let mut buf = vec![0u8; len - 16];
    s.read_exact(&mut buf)?;
    let resp: plist::Value =
        plist::from_bytes(&buf).map_err(|e| std::io::Error::other(e))?;
    let data = resp
        .as_dictionary()
        .and_then(|d| d.get("PairRecordData"))
        .and_then(|v| v.as_data())
        .ok_or_else(|| std::io::Error::other("no PairRecordData (device not paired?)"))?;
    Ok(data.to_vec())
}

/// Write one length-prefixed archive frame to stdout.
fn emit(out: &mut impl Write, bytes: &[u8]) -> std::io::Result<()> {
    out.write_all(&(bytes.len() as u32).to_le_bytes())?;
    out.write_all(bytes)?;
    out.flush()
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let udid = match args.get(1) {
        Some(u) if !u.starts_with('-') => u.clone(),
        _ => {
            eprintln!("usage: simcap-bridge <udid> [--follow]");
            std::process::exit(2);
        }
    };
    let follow = args.iter().any(|a| a == "--follow");
    let t0 = Instant::now();

    let pair = read_pair_record(&udid).unwrap_or_else(|e| {
        eprintln!("simcap-bridge: pair record: {e}");
        std::process::exit(1);
    });
    let pf = PairingFile::from_bytes(&pair).expect("parse pair record");
    eprintln!("pair record {:?}", t0.elapsed());

    let mut mux = UsbmuxdConnection::default().await.expect("usbmuxd");
    let devs = mux.get_devices().await.expect("devices");
    let dev = devs
        .into_iter()
        .find(|d| d.udid == udid && matches!(d.connection_type, Connection::Usb))
        .unwrap_or_else(|| {
            eprintln!("simcap-bridge: {udid} is not on USB (plug it in, unlock it)");
            std::process::exit(1);
        });
    let provider = Cable {
        usb: dev.to_provider(UsbmuxdAddr::default(), "simcap-bridge"),
        pf,
    };

    eprintln!("lockdown...");
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .expect("CoreDeviceProxy");
    let info = proxy.tunnel_info().clone();
    eprintln!(
        "CDTunnel up {:?}: rsd {} mtu {}",
        t0.elapsed(),
        info.server_rsd_port,
        info.mtu
    );
    let adapter = proxy.create_software_tunnel().expect("software tunnel");
    let mut adapter = adapter.to_async_handle();
    let stream = adapter
        .connect(info.server_rsd_port)
        .await
        .expect("rsd connect");
    let hs = RsdHandshake::new(stream).await.expect("rsd handshake");
    eprintln!("RSD {:?}: {} services", t0.elapsed(), hs.services.len());

    let svc = hs.services.get(AX_SERVICE).unwrap_or_else(|| {
        eprintln!("simcap-bridge: {AX_SERVICE} not published by the phone");
        std::process::exit(1);
    });
    let st = adapter.connect(svc.port).await.expect("AX service connect");
    eprintln!("AX service up {:?} on port {}", t0.elapsed(), svc.port);

    let mut c = idevice::dvt::remote_server::RemoteServerClient::new(st);

    // Publish the capabilities the phone expects before it will talk DTX.
    let mut caps = plist::Dictionary::new();
    caps.insert("com.apple.private.DTXBlockCompression".into(), 2u64.into());
    caps.insert("com.apple.private.DTXConnection".into(), 1u64.into());
    if let Err(e) = c
        .root_channel()
        .call_method(
            Some("_notifyOfPublishedCapabilities:"),
            Some(vec![idevice::dvt::message::AuxValue::archived_value(
                plist::Value::Dictionary(caps),
            )]),
            false,
        )
        .await
    {
        eprintln!("simcap-bridge: publish capabilities: {e:?}");
        std::process::exit(1);
    }
    // Drain the phone's own capability handshake.
    for _ in 0..2 {
        let _ = tokio::time::timeout(Duration::from_secs(3), c.root_channel().read_message()).await;
    }

    // Ask for the accessibility tree. clientNeedsAccessibility: flips the phone
    // into pushing processDataFromRemoteDevice: tree dumps.
    for sel in ["deviceAPIVersion", "clientNeedsAccessibility:"] {
        let a = if sel.ends_with(':') {
            Some(vec![idevice::dvt::message::AuxValue::archived_value(
                plist::Value::Boolean(true),
            )])
        } else {
            None
        };
        c.root_channel()
            .call_method(Some(sel), a, true)
            .await
            .unwrap_or_else(|e| panic!("{sel}: {e:?}"));
    }

    let mut out = std::io::stdout().lock();
    let mut frames = 0u32;
    let start = Instant::now();
    loop {
        if !follow && start.elapsed() > HARD_CAP {
            break;
        }
        let wait = if follow { Duration::from_secs(3600) } else { QUIET_AFTER };
        match tokio::time::timeout(wait, c.root_channel().read_message()).await {
            Ok(Ok(m)) => {
                // A tree-dump message carries the archive as an Array aux value.
                // Emit only archives that carry a dump-type marker, so the
                // phone's orientation message and other chatter never reach the
                // decoder. One-shot stops after the first AdditionalData dump.
                let mut saw_additional = false;
                if let Some(aux) = m.aux.as_ref() {
                    for v in &aux.values {
                        if let idevice::dvt::message::AuxValue::Array(bytes) = v {
                            let additional = contains(bytes, MARK_ADDITIONAL);
                            if !additional && !contains(bytes, MARK_INITIAL) {
                                continue;
                            }
                            if emit(&mut out, bytes).is_err() {
                                return; // loupe closed the pipe
                            }
                            frames += 1;
                            saw_additional |= additional;
                        }
                    }
                }
                if saw_additional && !follow {
                    break;
                }
            }
            Ok(Err(e)) => {
                eprintln!("simcap-bridge: read: {e:?}");
                break;
            }
            Err(_) => {
                // Timed out waiting for the next message. One-shot fallback: if
                // dumps already landed, the phone has gone quiet; otherwise it
                // never sent a tree.
                if !follow {
                    if frames == 0 {
                        eprintln!("simcap-bridge: no tree dump within {QUIET_AFTER:?}");
                    }
                    break;
                }
            }
        }
    }
    eprintln!("simcap-bridge: {frames} frame(s) in {:?}", t0.elapsed());
    if frames == 0 {
        std::process::exit(1);
    }
}
