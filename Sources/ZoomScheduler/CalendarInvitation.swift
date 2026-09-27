import Foundation

/// Find a complete invitation, deduplicating AX values/titles and nested copies.
/// Multiple distinct invitation bodies are rejected rather than choosing a meeting.
func matchingInvitation(in texts: [String], topic: String) throws -> String? {
    guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let candidates = Set(texts.filter { text in
        text.localizedCaseInsensitiveContains(topic) &&
        text.range(of: #"https?://(?:[A-Za-z0-9-]+\.)*(?:zoom\.us|zoom\.com|zoomgov\.com|zoom\.com\.cn|zoom\.us\.cn)(?::\d+)?/[^\s]+"#, options: .regularExpression) != nil
    })
    guard let longest = candidates.max(by: { $0.count < $1.count }) else { return nil }
    guard candidates.allSatisfy({ longest.contains($0) }) else {
        throw AutomationFailure("Multiple invitation texts match this topic. Select the intended meeting in Zoom; nothing was copied.")
    }
    return longest
}

/// Reads Zoom's own calendar export, not Outlook's calendar database.
struct CalendarInvitation {
    let topic: String
    let start: Date
    let uid: String
    let text: String
    let recurrenceRule: String?

    static func parse(_ content: String) -> CalendarInvitation? {
        var lines: [String] = []
        for line in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else { lines.append(line) }
        }
        var inEvent = false
        var nested = 0
        var events = 0
        var fields: [String: (header: String, value: String)] = [:]
        for line in lines {
            if line == "BEGIN:VEVENT" { events += 1; inEvent = true; continue }
            if line == "END:VEVENT" { inEvent = false; continue }
            guard inEvent else { continue }
            if line.hasPrefix("BEGIN:") { nested += 1; continue }
            if line.hasPrefix("END:") { nested -= 1; continue }
            guard nested == 0, let colon = line.firstIndex(of: ":") else { continue }
            let header = String(line[..<colon])
            let name = String(header.split(separator: ";")[0]).uppercased()
            fields[name] = (header, String(line[line.index(after: colon)...]))
        }
        guard events == 1,
              let summary = fields["SUMMARY"], let dt = fields["DTSTART"],
              let description = fields["DESCRIPTION"], let uid = fields["UID"],
              !uid.value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        if dt.value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            guard let parameter = dt.header.components(separatedBy: ";").first(where: { $0.hasPrefix("TZID=") }),
                  let zone = TimeZone(identifier: String(parameter.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else { return nil }
            formatter.timeZone = zone
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        guard let date = formatter.date(from: dt.value) else { return nil }
        let text = unescape(description.value)
        guard text.range(of: #"https?://[^\s]*zoom\.[^\s]+"#, options: .regularExpression) != nil else { return nil }
        return CalendarInvitation(topic: unescape(summary.value), start: date, uid: uid.value, text: text, recurrenceRule: fields["RRULE"]?.value)
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for char in value {
            if escaped {
                result.append(char == "n" || char == "N" ? "\n" : char)
                escaped = false
            } else if char == "\\" { escaped = true }
            else { result.append(char) }
        }
        if escaped { result.append("\\") }
        return result
    }

    var message: String {
        let repeatLine = recurrenceRule.map { "\nRepeat (iCalendar): \($0)" } ?? ""
        return "Topic: \(topic)\nTime: \(start.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier))\(repeatLine)\n\n\(text)"
    }

    static func find(topic: String, start: Date? = nil, directory: URL? = nil) throws -> CalendarInvitation? {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/zoom.us/data", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return nil }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let candidates = files.filter { $0.pathExtension.lowercased() == "ics" }
            .sorted { modified($0) > modified($1) }
        var matches: [String: CalendarInvitation] = [:]
        for url in candidates.prefix(200) {
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  info.isRegularFile == true, (info.fileSize ?? Int.max) < 1_000_000,
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  let event = parse(content), event.topic == topic,
                  start.map({ abs(event.start.timeIntervalSince($0)) < 60 }) ?? true else { continue }
            if matches[event.uid] == nil { matches[event.uid] = event }
        }
        guard matches.count <= 1 else {
            throw AutomationFailure("Multiple saved Zoom calendar exports match this topic. Use a unique topic or retrieve the intended invitation manually in Zoom.")
        }
        return matches.values.first
    }
}
