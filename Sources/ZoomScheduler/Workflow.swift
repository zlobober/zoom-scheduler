import AppKit

@MainActor
final class Workflow {
    // Both modes run the same executable inside the bundle and use its defaults domain.
    static let preferences = UserDefaults.standard
    let automation = ZoomAutomation()
    var log: (String) -> Void = { _ in }

    static func configuration(path: String? = nil) throws -> Configuration {
        if let path {
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let saved = preferences.string(forKey: "automationConfiguration")
        if let saved, saved != Configuration.legacySample {
            return try JSONDecoder().decode(Configuration.self, from: Data(saved.utf8))
        }
        return Configuration()
    }

    func run(topic: String, start: Date?, config: Configuration, invitationOnly: Bool = false, durationMinutes: Int? = nil, recurrence: Recurrence = .none, repeatEvery: Int = 1, repeatUntil: Date? = nil) async throws -> String {
        // Prevent two scheduler processes from manipulating the same Zoom UI.
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Zoom Scheduler")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("automation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AutomationFailure("Cannot open the automation lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw AutomationFailure("Another Zoom Scheduler operation is running.")
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            if let previousApp, !previousApp.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier {
                log("Restoring focus to \(previousApp.localizedName ?? "the previous app")…")
                if !previousApp.activate() { log("Could not restore the previous app's focus.") }
            }
        }

        automation.status = { [weak self] in self?.log($0) }
        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationFailure("Enter a meeting topic.") }
        let key = start.map { "\(topic)|\(Int($0.timeIntervalSince1970 / 60))" }
        Self.preferences.synchronize()
        let attempts = Self.preferences.stringArray(forKey: "submissionAttempts") ?? []
        if !invitationOnly, let key, attempts.contains(key) {
            let rules = Self.preferences.dictionary(forKey: "submissionRecurrences") as? [String: String] ?? [:]
            guard (rules[key] ?? Recurrence.none.rawValue) == recurrence.requestID(every: repeatEvery, until: repeatUntil) else {
                throw AutomationFailure("Submission was already attempted for this topic/time with a different repeat rule. It will not be changed or recreated. Check Zoom and use a unique topic for a new series.")
            }
        }
        if invitationOnly || key.map({ attempts.contains($0) }) == true {
            log("Retrieving the existing invitation only; not creating another meeting.")
            return try await automation.invitation(topic: topic, config: config, expectedStart: start)
        }
        guard let start, let key else { throw AutomationFailure("A start time is required to create a meeting.") }
        try validateMeeting(topic: topic, start: start)
        try recurrence.validate(start: start, every: repeatEvery, until: repeatUntil)
        automation.onSubmissionAttempt = {
            var saved = Self.preferences.stringArray(forKey: "submissionAttempts") ?? []
            saved.append(key)
            let retained = Array(saved.suffix(500))
            Self.preferences.set(retained, forKey: "submissionAttempts")
            var rules = Self.preferences.dictionary(forKey: "submissionRecurrences") as? [String: String] ?? [:]
            rules[key] = recurrence.requestID(every: repeatEvery, until: repeatUntil)
            rules = rules.filter { retained.contains($0.key) }
            Self.preferences.set(rules, forKey: "submissionRecurrences")
            Self.preferences.synchronize()
        }
        log("Creating “\(topic)” for \(start.formatted()) (\(TimeZone.current.identifier)).")
        log("Repeat: \(recurrence.title), interval \(repeatEvery); end \(repeatUntil.map(Recurrence.dateString) ?? "never").")
        if let durationMinutes { log("Duration: \(durationMinutes) minutes. Zoom’s security settings will be retained; external calendar import is disabled.") }
        else { log("Zoom’s duration and security settings will be retained; external calendar import is disabled.") }
        try await automation.prepare(topic: topic, start: start, config: config, durationMinutes: durationMinutes, recurrence: recurrence, repeatEvery: repeatEvery, repeatUntil: repeatUntil)
        try Task.checkCancellation()
        return try await automation.create(topic: topic, start: start, config: config, durationMinutes: durationMinutes, recurrence: recurrence, repeatEvery: repeatEvery, repeatUntil: repeatUntil)
    }
}
