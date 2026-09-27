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

    func run(topic: String, start: Date?, config: Configuration, invitationOnly: Bool = false, durationMinutes: Int? = nil) async throws -> String {
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

        automation.status = { [weak self] in self?.log($0) }
        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomationFailure("Enter a meeting topic.") }
        let key = start.map { "\(topic)|\(Int($0.timeIntervalSince1970 / 60))" }
        Self.preferences.synchronize()
        let attempts = Self.preferences.stringArray(forKey: "submissionAttempts") ?? []
        if invitationOnly || key.map({ attempts.contains($0) }) == true {
            log("Retrieving the existing invitation only; not creating another meeting.")
            return try await automation.invitation(topic: topic, config: config, expectedStart: start)
        }
        guard let start, let key else { throw AutomationFailure("A start time is required to create a meeting.") }
        try validateMeeting(topic: topic, start: start)
        automation.onSubmissionAttempt = {
            var saved = Self.preferences.stringArray(forKey: "submissionAttempts") ?? []
            saved.append(key)
            Self.preferences.set(Array(saved.suffix(500)), forKey: "submissionAttempts")
            Self.preferences.synchronize()
        }
        log("Creating “\(topic)” for \(start.formatted()) (\(TimeZone.current.identifier)).")
        if let durationMinutes { log("Duration: \(durationMinutes) minutes. Zoom’s security, recurrence, and calendar settings will be retained.") }
        else { log("Zoom’s duration, security, recurrence, and calendar settings will be retained.") }
        try await automation.prepare(topic: topic, start: start, config: config, durationMinutes: durationMinutes)
        try Task.checkCancellation()
        return try await automation.create(topic: topic, start: start, config: config, durationMinutes: durationMinutes)
    }
}
