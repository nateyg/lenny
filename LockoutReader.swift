import Foundation

/// Detects an actual "you've hit your limit" lockout from Claude Code's own
/// transcripts. When Claude Code refuses a request it writes an assistant entry
/// with `isApiErrorMessage: true`, `apiErrorStatus: 429`, and text like:
///
///     You've hit your session limit · resets 2:30pm (America/Los_Angeles)
///
/// That message states the reset time outright, so it beats the 5-hour estimate
/// whenever it's present. Text is read only to pull that time out.
enum LockoutReader {
	static var projectsDir: URL {
		URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
	}

	struct Lockout {
		var hitAt: Date
		var resetAt: Date
	}

	/// The most recent lockout whose reset time hasn't passed yet.
	static func current(now: Date = Date()) -> Lockout? {
		// A lockout that still matters was recorded within the last several hours.
		let cutoff = now.addingTimeInterval(-12 * 3600)
		var newest: Lockout?

		let fm = FileManager.default
		guard let walker = fm.enumerator(at: projectsDir,
		                                 includingPropertiesForKeys: [.contentModificationDateKey],
		                                 options: [.skipsHiddenFiles])
		else { return nil }

		let iso = ISO8601DateFormatter()
		iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let isoPlain = ISO8601DateFormatter()
		isoPlain.formatOptions = [.withInternetDateTime]

		for case let url as URL in walker {
			guard url.pathExtension == "jsonl" else { continue }
			let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate ?? .distantPast
			guard mod >= cutoff else { continue }
			guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

			for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
				guard line.contains("\"isApiErrorMessage\":true"),
				      line.contains("resets "),
				      line.contains("hit your")
				else { continue }
				guard let stamp = value(of: "timestamp", in: line),
				      let hitAt = iso.date(from: stamp) ?? isoPlain.date(from: stamp),
				      hitAt >= cutoff,
				      let reset = resetTime(in: String(line), hitAt: hitAt)
				else { continue }

				if newest == nil || hitAt > newest!.hitAt {
					newest = Lockout(hitAt: hitAt, resetAt: reset)
				}
			}
		}

		guard let newest, newest.resetAt > now else { return nil }
		return newest
	}

	private static func value(of key: String, in line: Substring) -> String? {
		guard let r = line.range(of: "\"\(key)\":\"") ?? line.range(of: "\"\(key)\": \"")
		else { return nil }
		let rest = line[r.upperBound...]
		guard let end = rest.firstIndex(of: "\"") else { return nil }
		return String(rest[..<end])
	}

	/// Parses `resets 2:30pm (America/Los_Angeles)` — the minutes are optional
	/// ("resets 2pm") — and resolves it to the first such wall-clock time at or
	/// after the moment the limit was hit.
	private static func resetTime(in line: String, hitAt: Date) -> Date? {
		let pattern = #"resets (\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)"#
		guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
		      let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
		else { return nil }

		func group(_ i: Int) -> String? {
			guard let r = Range(m.range(at: i), in: line) else { return nil }
			return String(line[r])
		}
		guard let hourStr = group(1), var hour = Int(hourStr),
		      let meridiem = group(3)?.lowercased(),
		      let zoneName = group(4), let zone = TimeZone(identifier: zoneName)
		else { return nil }
		let minute = Int(group(2) ?? "0") ?? 0

		if meridiem == "pm" && hour != 12 { hour += 12 }
		if meridiem == "am" && hour == 12 { hour = 0 }

		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = zone
		var parts = cal.dateComponents([.year, .month, .day], from: hitAt)
		parts.hour = hour
		parts.minute = minute
		parts.second = 0
		guard let sameDay = cal.date(from: parts) else { return nil }
		// "resets 1:10am" after a late-night lockout means tomorrow.
		return sameDay > hitAt ? sameDay : cal.date(byAdding: .day, value: 1, to: sameDay)
	}
}
