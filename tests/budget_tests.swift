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

        // QualitySteer against a model of the offline sizes: a delta frame grows
        // about 19x from Quality 0.3 to 0.6 (busy scroll 6 KB -> 115 KB).
        func size(_ q: Double, at06: Double) -> Int { Int(at06 * exp(9.8 * (q - 0.6))) }
        let frame = 16_667_000 as UInt64
        var st = QualitySteer(rateBps: 2_000_000, maxQ: 0.6)
        check(abs(st.target - 8333) < 1, "2 Mbps at 30 fps aims for 8,333 B, got \(st.target)")
        var now: UInt64 = 0
        for _ in 0..<10 { st.observe(size(st.q, at06: 115_000), now: now); now += frame }
        check(Double(size(st.q, at06: 115_000)) <= 1.5 * st.target, "busy scroll held near the target within 10 frames, q \(st.q)")
        var biggest = 0
        for _ in 0..<120 { let b = size(st.q, at06: 115_000); biggest = max(biggest, b); st.observe(b, now: now); now += frame }
        check(Double(biggest) <= 1.5 * st.target, "settled busy frames stay under 1.5x target, biggest \(biggest)")

        let busyQ = st.q
        for _ in 0..<60 { st.observe(size(st.q, at06: 1_000), now: now); now += frame } // 1 s of light content
        check(st.q <= busyQ * pow(1.03, 10) + 1e-9, "raises at most 3% per 100 ms, \(busyQ) -> \(st.q)")
        check(st.q > busyQ, "raises while frames are well under the target")

        var light = QualitySteer(rateBps: 2_000_000, maxQ: 0.6)
        for i in 0..<120 { light.observe(size(light.q, at06: 3_000), now: UInt64(i) * frame) }
        check(light.q == 0.6, "light content keeps the top quality, got \(light.q)")

        var floor = QualitySteer(rateBps: 500_000, maxQ: 0.6)
        for i in 0..<60 { floor.observe(500_000, now: UInt64(i) * frame) }
        check(floor.q == 0.1, "never below the floor, got \(floor.q)")

        var cap = QualitySteer(rateBps: 2_000_000, maxQ: 0.6)
        cap.setRate(4_000_000)
        check(abs(cap.target - 16_667) < 1, "a higher cap raises the target, got \(cap.target)")

        print(failures == 0 ? "budget: all passed" : "budget: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
