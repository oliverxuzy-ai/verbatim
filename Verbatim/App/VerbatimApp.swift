import AppKit
import SwiftUI

@main
struct VerbatimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(storeRoot: SelfChecks.uiProbeStoreRoot)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Dock icon by default: on a crowded menu bar the notch can hide
        // the status item, and the Dock always works.
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        // Unit tests use the app as host; skip windows and background work.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe-calendar"), i + 1 < args.count {
            let request = args.contains("--request")
            NSApp.setActivationPolicy(request ? .accessory : .prohibited)
            Task { await SelfChecks.calendar(writingTo: URL(fileURLWithPath: args[i + 1]), requestAccess: request); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--probe-calendar-roundtrip"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            Task { await SelfChecks.calendarRoundTrip(writingTo: URL(fileURLWithPath: args[i + 1])); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--probe-ui"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            model.windows.model = model
            model.panel.model = model
            Task { await SelfChecks.ui(model: model, writingTo: URL(fileURLWithPath: args[i + 1])); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--probe-menu"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            model.windows.model = model
            model.panel.model = model
            Task { await SelfChecks.menuButtons(model: model, writingTo: URL(fileURLWithPath: args[i + 1])); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--probe-identify"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            model.windows.model = model
            model.panel.model = model
            Task { await SelfChecks.identify(model: model, writingTo: URL(fileURLWithPath: args[i + 1])); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--probe-recording"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            Task { await SelfChecks.recording(writingTo: URL(fileURLWithPath: args[i + 1])); exit(0) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-system-audio"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            NSApp.setActivationPolicy(.prohibited)
            Task {
                await SystemAudioDiagnostics.run(writingTo: url)
                exit(0)
            }
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            DebugSnapshot.run(outputDir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if CommandLine.arguments.contains("--demo-session") {
            model.windows.model = model
            model.panel.model = model
            DebugSnapshot.runDemoSession(model: model)
            return
        }
        #endif
        model.launch()
        if model.settings.hasCompletedOnboarding { model.windows.showMain() }
        if CommandLine.arguments.contains("--show-main") { model.windows.showMain() }
        if CommandLine.arguments.contains("--show-settings") { model.windows.showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.windows.showMain()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording else { return .terminateNow }
        // Never lose a meeting on quit: stop and save first.
        Task { @MainActor in
            if let session = model.session { await session.stop() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Static icon only. A ticking timer or palette-rendered symbol in a
/// MenuBarExtra label sends SwiftUI into a status-item update loop that
/// pins the main thread (reproduced with --demo-session); elapsed time lives
/// in the capsule and the main window instead.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.isRecording {
            Image(systemName: "record.circle.fill")
        } else {
            Image(nsImage: BrandMark.menuBarImage)
        }
    }
}
