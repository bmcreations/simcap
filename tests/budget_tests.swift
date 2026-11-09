import Foundation

@main
struct BudgetTests {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL", what) }
    }

    static func main() {
        let ms: UInt64 = 1_000_000
        // 2 Mbps with 50 ms of credit: 12,500 bytes.
        var b = RateBudget(rateBps: 2_000_000, depthMs: 50, now: 0)
        check(b.allow(0), "starts with credit")
        b.spend(40_000, now: 0) // a 40 KB scroll frame: 27,500 bytes of debt
        check(!b.allow(16 * ms), "skips while in debt")
        check(abs(Double(b.untilClear()) / 1e6 - 94) < 2, "debt clears in about 94 ms, got \(Double(b.untilClear()) / 1e6)")
        check(!b.allow(100 * ms), "still in debt at 100 ms")
        check(b.allow(111 * ms), "clear by 111 ms")
        check(b.allow(10_000 * ms) && b.tokens <= 12_500, "credit never above the depth")

        // A burst like the bench's 2 Mbps runs (3 KB frames, then 15-45 KB as a
        // scroll lands) fed through the budget into a 2 Mbps link: queueing stays
        // within the depth plus the largest single frame's link time.
        let burst = [3000, 3000, 45000, 30000, 15000, 15000, 3000, 40000, 20000, 3000, 3000, 3000]
        var link = 0.0, worst = 0.0, sent = 0
        var bb = RateBudget(rateBps: 2_000_000, depthMs: 50, now: 0)
        for i in 0..<240 {
            let now = UInt64(i) * 16_667_000
            guard bb.allow(now) else { continue }
            let bytes = burst[i % burst.count]
            bb.spend(bytes, now: now)
            let t = Double(now) / 1e9
            link = max(link, t) + Double(bytes) * 8 / 2_000_000
            worst = max(worst, link - t)
            sent += 1
        }
        check(worst < 0.050 + 0.180 + 0.01, "queue \(Int(worst * 1000)) ms within 50 ms depth + one 45 KB frame")
        // The burst averages 15 KB a frame, 7 Mbps at 60 fps; 2 Mbps carries about 65 of them in 4 s.
        check(sent >= 50, "still sends \(sent) of 240")

        var unbudgeted = 0.0, worstOff = 0.0
        for i in 0..<240 {
            let t = Double(i) / 60
            unbudgeted = max(unbudgeted, t) + Double(burst[i % burst.count]) * 8 / 2_000_000
            worstOff = max(worstOff, unbudgeted - t)
        }
        check(worstOff > 1.0, "without the budget the same burst queues past 1 s (\(Int(worstOff * 1000)) ms)")

        // Off: always allows, never in debt.
        var off = RateBudget(rateBps: 2_000_000, depthMs: 0, now: 0)
        off.spend(1_000_000, now: 0)
        check(off.allow(0), "depth 0 turns the budget off")

        // A lower cap drops credit above the new depth.
        var r = RateBudget(rateBps: 4_000_000, depthMs: 50, now: 0)
        r.setRate(1_000_000, now: 0)
        check(r.tokens <= 6_250, "setRate trims credit to the new depth")

        print(failures == 0 ? "budget: all passed" : "budget: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
