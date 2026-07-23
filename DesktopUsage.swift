import Foundation

/// Reads the Claude **desktop** app's own usage history — the authoritative
/// source when you code through Claude Desktop rather than the CLI.
///
/// The app writes `~/Library/Application Support/Claude/plan-usage-history.json`
/// every ~5 minutes: a list of samples, each `{t: <ms>, u: {fh, sd}}`, where
/// `fh` is your 5-hour-limit usage as a percentage (0–100) and `sd` the weekly
/// figure. This is exactly what the app's "Plan usage limits" panel draws from,
/// so tying Lenny to it makes the countdown match what you actually see.
///
/// It gives a percentage, not a reset time, so the block is reconstructed: `fh`
/// collapses to ~0 when a 5-hour window resets, activity resumes moments later,
/// and Claude anchors the block to that first message floored to ten minutes
/// (the same rule the CLI path uses). Verified against the app's own panel:
/// reconstructed reset landed within a few minutes of the displayed time.
enum DesktopUsage {
    struct State {
        var fivePct: Int          // 0…100, the 5-hour limit
        var resetAt: Date
        var blockStart: Date
        /// At the ceiling — treat as locked out.
        var isMaxed: Bool { fivePct >= 100 }
    }

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    private struct Sample { let t: Date; let fh: Int }

    static func current(now: Date = Date()) -> State? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["samples"] as? [[String: Any]]
        else { return nil }

        let samples: [Sample] = raw.compactMap { s in
            guard let ms = s["t"] as? Double,
                  let u = s["u"] as? [String: Any],
                  let fh = u["fh"] as? Int else { return nil }
            return Sample(t: Date(timeIntervalSince1970: ms / 1000), fh: fh)
        }.sorted { $0.t < $1.t }

        guard let newest = samples.last else { return nil }
        // Stale file (app closed for hours) can't describe the current window.
        guard now.timeIntervalSince(newest.t) < 6 * 3600 else { return nil }

        let window = samples.filter { now.timeIntervalSince($0.t) < 6 * 3600 }
        guard window.count >= 2 else { return nil }

        // The current block opens at the first activity after the most recent
        // reset (the last big downward step in fh, or a run of zeros).
        var resetIdx = 0
        for i in 1..<window.count where window[i].fh < window[i - 1].fh - 10 {
            resetIdx = i
        }
        var startIdx = resetIdx
        while startIdx < window.count && window[startIdx].fh == 0 { startIdx += 1 }
        startIdx = min(startIdx, window.count - 1)

        // That first non-zero sample already reflects usage that happened *before*
        // it — sometimes well before, when the app was closed during the block's
        // real start and there's a long gap with no samples. Pull the anchor back
        // by that blind gap (capped at one bucket) so the estimate stops landing
        // late; on a normal ~5-minute cadence this is a no-op after flooring.
        let firstActivity = window[startIdx].t
        let priorGap = startIdx > 0 ? firstActivity.timeIntervalSince(window[startIdx - 1].t) : 0
        let anchor = firstActivity.addingTimeInterval(-min(priorGap, 600))

        let blockStart = floorToBucket(anchor)
        let resetAt = blockStart.addingTimeInterval(TranscriptReader.blockHours)
        // If our reconstruction already expired, the file is mid-reset; bail so the
        // caller falls back rather than showing a stale window.
        guard resetAt > now else { return nil }

        return State(fivePct: newest.fh, resetAt: resetAt, blockStart: blockStart)
    }

    private static func floorToBucket(_ d: Date) -> Date {
        let bucket: TimeInterval = 600
        return Date(timeIntervalSinceReferenceDate:
                        (d.timeIntervalSinceReferenceDate / bucket).rounded(.down) * bucket)
    }
}
