import SwiftUI
import AppKit

struct ZoomSchedulerApp: App {
    var body: some Scene {
        WindowGroup("Zoom Scheduler") { SchedulerView() }
            .defaultSize(width: 740, height: 760)
    }
}

@MainActor
@Observable
final class SchedulerModel {
    var topic = Workflow.preferences.string(forKey: "lastTopic") ?? "" {
        didSet { Workflow.preferences.set(topic, forKey: "lastTopic") }
    }
    var start = (Workflow.preferences.object(forKey: "lastStart") as? Date) ?? Date().addingTimeInterval(3600) {
        didSet { Workflow.preferences.set(start, forKey: "lastStart") }
    }
    var invitation = ""
    var log = ""
    var busy = false
    var task: Task<Void, Never>?
    let workflow = Workflow()

    func append(_ message: String) {
        log += "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
    }

    func create() {
        guard !busy else { return }
        if !ZoomAutomation.trusted {
            ZoomAutomation.requestPermission()
            append("Enable Zoom Scheduler in System Settings → Privacy & Security → Accessibility, then try again.")
            return
        }
        Workflow.preferences.set(topic, forKey: "lastTopic")
        Workflow.preferences.set(start, forKey: "lastStart")
        busy = true
        invitation = ""
        log = ""
        workflow.log = { [weak self] in self?.append($0) }
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            do {
                invitation = try await workflow.run(topic: topic, start: start, config: Workflow.configuration())
                append("Done. Invitation is ready below.")
            } catch is CancellationError {
                append("Stopped. Any meeting already submitted remains in Zoom.")
            } catch {
                append("ERROR: \(error.localizedDescription)")
                append("If submission was attempted, repeating this same topic/time will retrieve only, not create a duplicate.")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

struct SchedulerView: View {
    @State private var model = SchedulerModel()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Zoom Scheduler").font(.largeTitle.bold())
            TextField("Meeting topic", text: $model.topic)
                .textFieldStyle(.roundedBorder).disabled(model.busy)
            DatePicker("Starts", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
                .disabled(model.busy)
            Text("\(TimeZone.current.identifier) · Uses Zoom’s current duration and meeting options. Creates immediately for the chosen time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.busy ? "Stop" : "Create meeting") {
                    if model.busy { model.task?.cancel() } else { model.create() }
                }.buttonStyle(.borderedProminent)
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text("Action log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "Ready. Sign in to Zoom before starting." : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8).frame(height: 200).border(.quaternary)
                .onChange(of: model.log) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack {
                Text("Invitation").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.invitation, forType: .string)
                }.disabled(model.invitation.isEmpty)
            }
            ScrollView {
                Text(model.invitation.isEmpty ? "The invitation will appear here." : model.invitation)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.invitation.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(8).frame(minHeight: 150, maxHeight: .infinity).border(.quaternary)
        }
        .padding(20).frame(minWidth: 620, minHeight: 680)
    }
}
