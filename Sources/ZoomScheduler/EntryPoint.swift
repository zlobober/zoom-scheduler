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
        let task = Task { @MainActor in
            do {
                guard ZoomAutomation.trusted else {
                    throw AutomationFailure("Accessibility access is required. Open Zoom Scheduler once and click Create meeting to request permission, then enable it in System Settings. Your terminal may also require permission.")
                }
                let config = try Workflow.configuration(path: options.configPath)
                if options.inspect {
                    let previousApp = NSWorkspace.shared.frontmostApplication
                    defer { if let previousApp, !previousApp.isTerminated { previousApp.activate() } }
                    print(try await ZoomAutomation().snapshot(config: config))
                } else {
                    let workflow = Workflow()
                    workflow.log = { stderr($0) }
                    let invitation = try await workflow.run(topic: options.topic!, start: options.start,
                                                           config: config, invitationOnly: options.invitationOnly, durationMinutes: options.durationMinutes, recurrence: options.recurrence,
                                                           repeatEvery: options.repeatEvery, repeatUntil: options.repeatUntil)
                    print(invitation)
                }
                exit(0)
            } catch {
                stderr("ERROR: \(error.localizedDescription)")
                stderr("If submission was attempted, do not create a duplicate. Retry the same topic/time or use --invitation-only.")
                exit(1)
            }
        }
        // Graceful CLI cancellation lets Workflow restore focus and release its
        // lock. SIGKILL/process crashes cannot perform cleanup.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler { task.cancel() }
        terminate.setEventHandler { task.cancel() }
        interrupt.resume()
        terminate.resume()
        withExtendedLifetime((interrupt, terminate)) { app.run() }
    }

    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
