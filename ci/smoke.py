#!/usr/bin/env python3
"""Smoke-test simcap against a booted simulator on this machine.

Boots an iPhone simulator, streams it with `simcap <udid>` while sending
swipes through `simcap <udid> -input`, then parses the stream and reports
what arrived. Written for a hosted CI runner, where the open questions are
whether SimulatorKit hands out surfaces and VideoToolbox encodes at all on a
virtual machine; it runs the same on a desk Mac.

    ci/smoke.py [out-dir]     default .build/smoke

Exits non-zero when the stream has too few frames, no keyframe, or an input
command did not answer `ok`.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import time

SIMCAP = ".build/simcap"
CAPTURE_SECS = 12
MIN_FRAMES = 30
FLAG_CONFIG = 1 << 63
FLAG_KEY = 1 << 62


def run(*cmd, timeout=120):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def pick_simulator():
    """The first available iPhone on the newest iOS runtime."""
    _, out = run("xcrun", "simctl", "list", "-j", "devices", "available")
    best = None
    for runtime, devices in json.loads(out)["devices"].items():
        if "iOS" not in runtime:
            continue
        version = tuple(int(n) for n in runtime.rsplit("iOS-", 1)[-1].split("-") if n.isdigit())
        for d in devices:
            if d["name"].startswith("iPhone") and (best is None or version > best[0]):
                best = (version, d["udid"], d["name"], runtime)
    if best is None:
        sys.exit("no available iPhone simulator")
    return best[1], best[2], best[3]


def parse(path, h264_path):
    """Read simcap's stream: a 64-byte name, codec, width, height, then
    packets of (pts|flags: u64, length: u32, payload). A capture that was
    killed mid-write ends in a short packet, which is dropped."""
    data = open(path, "rb").read()
    r = {"bytes": len(data), "frames": 0, "keyframes": 0, "configs": 0}
    if len(data) < 76:
        return r
    r["name"] = data[:64].rstrip(b"\0").decode("utf-8", "replace")
    codec, r["width"], r["height"] = struct.unpack(">4sII", data[64:76])
    r["codec"] = codec.decode("ascii", "replace")
    off, pts = 76, []
    with open(h264_path, "wb") as h264:
        while off + 12 <= len(data):
            head, size = struct.unpack(">QI", data[off:off + 12])
            if off + 12 + size > len(data):
                break
            h264.write(data[off + 12:off + 12 + size])
            off += 12 + size
            if head & FLAG_CONFIG:
                r["configs"] += 1
                continue
            r["frames"] += 1
            r["keyframes"] += 1 if head & FLAG_KEY else 0
            pts.append(head & ~(FLAG_CONFIG | FLAG_KEY))
    if len(pts) > 1:
        r["seconds"] = round((pts[-1] - pts[0]) / 1e6, 2)
        gaps = sorted(b - a for a, b in zip(pts, pts[1:]))
        r["gap_ms_p50"] = round(gaps[len(gaps) // 2] / 1000, 1)
        r["gap_ms_max"] = round(gaps[-1] / 1000, 1)
        if r["seconds"] > 0:
            r["fps"] = round((len(pts) - 1) / r["seconds"], 1)
    return r


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else ".build/smoke"
    os.makedirs(out, exist_ok=True)
    report, failures = [], []

    def note(title, body):
        report.append(f"### {title}\n\n```\n{body}\n```\n")
        print(f"== {title}\n{body}\n", flush=True)

    host = [run("sw_vers")[1], run("xcodebuild", "-version")[1],
            run("sysctl", "-n", "hw.model", "machdep.cpu.brand_string")[1]]
    note("Host", "\n".join(host))
    note("Displays and GPU", run("system_profiler", "SPDisplaysDataType")[1])
    note("simcap -caps", run(SIMCAP, "-caps")[1])

    udid, name, runtime = pick_simulator()
    t0 = time.time()
    code, boot = run("xcrun", "simctl", "boot", udid, timeout=300)
    if code != 0 and "current state: Booted" not in boot:
        sys.exit(f"simctl boot failed: {boot}")
    run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    note("Simulator", f"{name}  {udid}\n{runtime}\nbooted in {time.time() - t0:.0f}s")

    stream = os.path.join(out, "stream.bin")
    with open(stream, "wb") as so, open(os.path.join(out, "simcap.log"), "wb") as se:
        cap = subprocess.Popen([SIMCAP, udid, "-fps", "30"], stdout=so, stderr=se)
        time.sleep(3)

        # Swipes across the home screen give the encoder motion and test the
        # input path at once. Coordinates are framebuffer pixels.
        cmds = ["size"]
        for _ in range(3):
            cmds += ["swipe 900 1200 200 1200 300", "swipe 200 1200 900 1200 300"]
        cmds += ["button home"]
        replies = "(no reply)"
        try:
            p = subprocess.run([SIMCAP, udid, "-input"], input="\n".join(cmds) + "\n",
                               capture_output=True, text=True, timeout=60)
            replies = p.stdout.strip() or p.stderr.strip() or f"(exit {p.returncode}, no output)"
            lines = p.stdout.strip().splitlines()
            if len(lines) != len(cmds) or not all(l.startswith("ok") for l in lines):
                failures.append(f"input: {len(lines)} replies to {len(cmds)} commands, not all ok")
        except subprocess.TimeoutExpired:
            failures.append("input: no answer within 60s")
        note("Input replies", "\n".join(f"{c:32} -> {r}" for c, r in
                                        zip(cmds, replies.splitlines() + [""] * len(cmds))))

        time.sleep(max(0, CAPTURE_SECS - 3))
        early = cap.poll()
        cap.terminate()
        try:
            cap.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cap.kill()
    if early is not None:
        failures.append(f"capture: simcap exited on its own with status {early}")

    log = open(os.path.join(out, "simcap.log"), errors="replace").read().strip()
    note("simcap stderr", log[-3000:] or "(empty)")

    h264 = os.path.join(out, "stream.h264")
    r = parse(stream, h264)
    note("Stream", json.dumps(r, indent=2))
    if r["frames"] < MIN_FRAMES:
        failures.append(f"stream: {r['frames']} frames in {CAPTURE_SECS}s, want at least {MIN_FRAMES}")
    if r["keyframes"] == 0:
        failures.append("stream: no keyframe")

    # simctl's own screenshot, for comparing against a decoded stream frame.
    run("xcrun", "simctl", "io", udid, "screenshot", os.path.join(out, "simctl-screenshot.png"))
    if shutil.which("ffmpeg") and r["frames"]:
        frame = os.path.join(out, "stream-frame.png")
        code, msg = run("ffmpeg", "-y", "-loglevel", "error", "-i", h264, "-vf",
                        f"select=eq(n\\,{r['frames'] // 2})", "-frames:v", "1", frame)
        run("ffmpeg", "-y", "-loglevel", "error", "-r", "30", "-i", h264, "-c", "copy",
            os.path.join(out, "stream.mp4"))
        note("Decode", "decoded a mid-stream frame to stream-frame.png" if code == 0 else f"ffmpeg failed: {msg}")
        if code != 0:
            failures.append("decode: ffmpeg could not decode the stream")
    else:
        note("Decode", "skipped: no ffmpeg on PATH, or no frames")

    verdict = "PASS" if not failures else "FAIL\n" + "\n".join(f"- {f}" for f in failures)
    print(f"== Result\n{verdict}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"## simcap simulator smoke: {verdict}\n\n" + "\n".join(report))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
