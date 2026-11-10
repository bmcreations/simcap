// RateBudget is the remote track's frame budget: a token bucket that fills at
// the rate cap and holds depthMs of credit. VideoToolbox's DataRateLimits only
// holds the average over its window: with a 33 ms window at 2 Mbps a single
// frame still came out at 42 KB, 170 ms of that link. So the remote encoder
// skips captures while the bucket is in debt, the way voxl skips while frames
// are in flight, and a scroll burst queues at most about depthMs on a link
// that carries the cap. Times are uptime nanoseconds.
struct RateBudget {
    private(set) var rateBps: Int
    let depthMs: Int
    private(set) var tokens: Double
    private var last: UInt64

    init(rateBps: Int, depthMs: Int, now: UInt64) {
        self.rateBps = max(1, rateBps)
        self.depthMs = depthMs
        self.last = now
        self.tokens = 0
        self.tokens = depth
    }

    var depth: Double { Double(rateBps) / 8 * Double(depthMs) / 1000 }

    // setRate changes the fill rate; credit above the new depth is dropped.
    mutating func setRate(_ bps: Int, now: UInt64) {
        refill(now)
        rateBps = max(1, bps)
        tokens = min(tokens, depth)
    }

    mutating func refill(_ now: UInt64) {
        guard now > last else { return }
        tokens = min(depth, tokens + Double(rateBps) / 8 * Double(now - last) / 1e9)
        last = now
    }

    // allow says whether a frame may be encoded now. Off (depthMs 0) always allows.
    mutating func allow(_ now: UInt64) -> Bool {
        guard depthMs > 0 else { return true }
        refill(now)
        return tokens >= 0
    }

    mutating func spend(_ bytes: Int, now: UInt64) {
        guard depthMs > 0 else { return }
        refill(now)
        tokens -= Double(bytes)
    }

    // untilClear is how long until the debt is paid, in nanoseconds; 0 when there is none.
    func untilClear() -> UInt64 {
        tokens >= 0 ? 0 : UInt64(-tokens / (Double(rateBps) / 8) * 1e9) + 1
    }
}

// QualitySteer sets the remote encoder's Quality from the size of the frames it
// makes. VideoToolbox ignores Quality once DataRateLimits is set: under a 2 Mbps
// limit a busy scroll came out at 30-57 KB a frame whatever the quality, and the
// budget above could only skip. Without the limit Quality sets the size, so the
// steer holds delta frames near cap / 8 / fps: it cuts at once on a frame over
// the target, in proportion to the overshoot, and raises 3% at most every 100 ms
// while frames come in well under it. Keyframes are left out; they are asked for.
// Offline, on noisy photo rows scrolling 96 px a frame at 2 Mbps, delta frames
// went from 35-45 KB to 6 KB (p90), and a live change takes effect on the next
// frame without a new SPS. Times are uptime nanoseconds.
struct QualitySteer {
    let minQ: Double
    let maxQ: Double
    let fps: Double
    private(set) var q: Double
    private(set) var rateBps: Int
    private var lastRaise: UInt64 = 0

    init(rateBps: Int, maxQ: Double, minQ: Double = 0.1, fps: Double = 30) {
        self.rateBps = max(1, rateBps)
        self.maxQ = maxQ
        self.minQ = min(minQ, maxQ)
        self.fps = fps
        self.q = maxQ
    }

    // target is the byte size a delta frame aims for.
    var target: Double { Double(rateBps) / 8 / fps }

    mutating func setRate(_ bps: Int) { rateBps = max(1, bps) }

    // observe takes one delta frame's size.
    mutating func observe(_ bytes: Int, now: UInt64) {
        let b = Double(bytes), t = target
        if b > 1.5 * t {
            q *= max(0.5, (t / b).squareRoot())
        } else if b > t {
            q *= 0.95
        } else if b < 0.6 * t, now >= lastRaise + 100_000_000 {
            q *= 1.03
            lastRaise = now
        }
        q = min(maxQ, max(minQ, q))
    }
}
