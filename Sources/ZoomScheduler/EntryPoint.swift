import AppKit

@main
struct EntryPoint {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.allSatisfy({ $0.hasPrefix("-psn_") }) {
            ZoomSchedulerApp.main()
            return
        }
        let options: CLIOptions
        do { options = try CLIOptions(arguments: args) }
        catch {
            stderr("ERROR: \(error.localizedDescription)\n\n\(CLIOptions.usage)")
            exit(2)
        }
        if options.help { print(CLIOptions.usage); return }
        if options.printConfig { print(Configuration.sample); return }

        // Run AppKit's event loop for AX/NSWorkspace, without creating a window,
        // Dock icon, or activating the scheduler application.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                guard ZoomAutomation.trusted else {
                    throw AutomationFailure("Accessibility access is required. Open Zoom Scheduler once and click Create meeting to request permission, then enable it in System Settings. Your terminal may also require permission.")
                }
                let config = try Workflow.configuration(path: options.configPath)
                if options.inspect {
                    print(try await ZoomAutomation().snapshot(config: config))
                } else {
                    let workflow = Workflow()
                    workflow.log = { stderr($0) }
                    let invitation = try await workflow.run(topic: options.topic!, start: options.start,
                                                           config: config, invitationOnly: options.invitationOnly, durationMinutes: options.durationMinutes)
                    print(invitation)
                }
                exit(0)
            } catch {
                stderr("ERROR: \(error.localizedDescription)")
                stderr("If submission was attempted, do not create a duplicate. Retry the same topic/time or use --invitation-only.")
                exit(1)
            }
        }
        app.run()
    }

    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
