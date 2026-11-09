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
