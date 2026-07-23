import Foundation

/// Reads Claude Code's local transcripts and derives the active 5-hour block:
/// floor the block's first message to **10 minutes**, add 5 hours.
///
/// The 10 minutes is not a guess. Every lockout message Claude Code writes
/// states its own reset time, so `reset - 5h` gives a ground-truth block start.
/// Across twelve real lockouts every one of those starts landed exactly on a
/// ten-minute boundary (02:30, 03:40, 20:30, 17:00, …) and never on the hour.
/// Replaying the rule over that history reproduces 10 of 11 resets to the
/// second; hour-flooring managed 3 of 17 and ran up to 59 minutes early.
///
/// The first message must include **user** messages, not just assistant
/// replies: a block begins when you send something, and the assistant's first
/// billable response lands 2–10 minutes later, which is enough to slip into the
/// next ten-minute bucket.
///
/// Reads timestamps only — never message content.
enum TranscriptReader {
    static let blockHours: TimeInterval = 5 * 3600
    static var projectsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Claude Code's own transcripts, plus the desktop app's local-agent sessions,
    /// which keep their own `.claude/projects` and spend the same 5-hour budget.
    ///
    /// Still invisible from here: plain Claude desktop/web chats, and anything on
    /// another machine. Those share the limit but leave nothing on disk, so the
    /// block anchor can be wrong when you've been working outside the CLI.
    static var searchRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots = [projectsDir]
        let agentSessions = home.appendingPathComponent(
            "Library/Application Support/Claude/local-agent-mode-sessions")
        if let walker = FileManager.default.enumerator(
            at: agentSessions, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker where url.lastPathComponent == "projects"
            && url.deletingLastPathComponent().lastPathComponent == ".claude" {
                roots.append(url)
            }
        }
        return roots
    }

    struct Block {
        var start: Date
        var last: Date
        var msgs: Int
        var reset: Date { start.addingTimeInterval(blockHours) }
    }

    /// Timestamps of every user and assistant message, newest window only.
    /// Only opens files touched recently — Nate's transcripts are ~11k messages.
    private static func timestamps(since cutoff: Date) -> [Date] {
        let fm = FileManager.default
        var out: [Date] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        let walkers = searchRoots.compactMap {
            fm.enumerator(at: $0, includingPropertiesForKeys: [.contentModificationDateKey],
                          options: [.skipsHiddenFiles])
        }
        for case let url as URL in walkers.flatMap({ $0.compactMap { $0 as? URL } }) {
            guard url.pathExtension == "jsonl" else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mod >= cutoff else { continue }   // skip cold files entirely
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // cheap prefilter before any parsing
                guard line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")
                        || line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"")
                else { continue }
                guard let r = line.range(of: "\"timestamp\":\"") ?? line.range(of: "\"timestamp\": \"")
                else { continue }
                let rest = line[r.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { continue }
                let raw = String(rest[..<end])
                if let d = iso.date(from: raw) ?? isoPlain.date(from: raw), d >= cutoff {
                    out.append(d)
                }
            }
        }
        return out.sorted()
    }

    /// The block containing `now`, if any. Nil when idle (no window running).
    static func activeBlock(now: Date = Date()) -> Block? {
        // A block can only start within the last 5h, so that's all we need to read.
        let stamps = timestamps(since: now.addingTimeInterval(-blockHours * 2))
        guard !stamps.isEmpty else { return nil }

        var blocks: [Block] = []
        var cur: Block?
        for t in stamps {
            if var c = cur,
               t.timeIntervalSince(c.start) < blockHours,
               t.timeIntervalSince(c.last) < blockHours {
                c.msgs += 1; c.last = t; cur = c
            } else {
                if let c = cur { blocks.append(c) }
                cur = Block(start: floorToBucket(t), last: t, msgs: 1)
            }
        }
        if let c = cur { blocks.append(c) }

        return blocks.first { $0.start <= now && now < $0.reset }
    }

    /// Blocks start on a ten-minute boundary — see the note at the top.
    private static func floorToBucket(_ d: Date) -> Date {
        let bucket: TimeInterval = 600
        return Date(timeIntervalSinceReferenceDate:
                        (d.timeIntervalSinceReferenceDate / bucket).rounded(.down) * bucket)
    }
}
