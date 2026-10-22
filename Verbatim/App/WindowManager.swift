import AppKit
import SwiftUI

/// Owns the regular windows. The app lives in the menu bar; while a window
/// is open it also shows in the Dock and Cmd-Tab.
final class WindowManager: NSObject, NSWindowDelegate {
    weak var model: AppModel?
    private var main: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?

    func showMain() {
        guard let model else { return }
        if main == nil {
            main = makeWindow(
                title: "Verbatim",
                size: NSSize(width: 1040, height: 680),
                minSize: NSSize(width: 760, height: 460),
                autosave: "VerbatimMain",
                content: MainWindowView(model: model)
            )
            main?.titlebarAppearsTransparent = true
            main?.titleVisibility = .hidden
            main?.styleMask.insert(.fullSizeContentView)
        }
        present(main)
    }

    func showSettings(section: SettingsView.Section? = nil) {
        guard let model else { return }
        if let section { model.settingsSection = section }
        if settings == nil {
            settings = makeWindow(
                title: "Settings",
                size: NSSize(width: 640, height: 560),
                minSize: NSSize(width: 560, height: 440),
                autosave: "VerbatimSettings",
                content: SettingsView(model: model)
            )
            settings?.titlebarAppearsTransparent = true
            settings?.titleVisibility = .hidden
            settings?.styleMask.insert(.fullSizeContentView)
        }
        present(settings)
    }

    func showOnboarding() {
        guard let model else { return }
        if onboarding == nil {
            onboarding = makeWindow(
                title: "Welcome to Verbatim",
                size: NSSize(width: 560, height: 600),
                minSize: NSSize(width: 520, height: 560),
                autosave: nil,
                content: OnboardingView(model: model) { [weak self] in
                    self?.onboarding?.close()
                    self?.showMain()
                }
            )
            onboarding?.styleMask.remove(.resizable)
        }
        present(onboarding)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, minSize: NSSize, autosave: String?, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content.background(Theme.bg))
        window.setContentSize(size)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(Theme.bg)
        // Opened from the menu bar, a window should come up where the user is:
        // on the current desktop, even over a full-screen meeting app, not
        // back on whatever Space it was last shown on.
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        if let autosave {
            window.setFrameAutosaveName(autosave)
            if !window.setFrameUsingName(autosave) { window.center() }
        } else {
            window.center()
        }
        return window
    }

    /// Self checks: start from a clean screen.
    func hideAll() {
        [main, settings, onboarding].forEach { $0?.orderOut(nil) }
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // A saved frame on a monitor that is no longer attached would open
        // the window where nobody can see it.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame.insetBy(dx: 40, dy: 40)) }) {
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        // activate() is only a request on macOS 14+ and is ignored while the
        // user works in another app; orderFrontRegardless still shows it.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = [self.main, self.settings, self.onboarding].contains { $0?.isVisible == true }
            if !anyVisible, self.model?.settings.showInDock == false { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
