import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel shown while recording.
/// It never steals focus from the meeting app and is excluded from screen
/// sharing so other participants don't see it.
final class RecordingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 170),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the capsule draws its own soft shadow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FloatingPanelController {
    weak var model: AppModel?
    private var panel: RecordingPanel?
    private let state = PanelState()

    func show() {
        guard let model else { return }
        state.error = nil
        if panel == nil {
            let panel = RecordingPanel()
            let host = NSHostingView(rootView: RecordingPanelView(model: model, state: state) { [weak self] in
                self?.resize()
            })
            // Sized explicitly in resize(); letting the host track its
            // intrinsic size re-measured the window on every level update.
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
            panel.setFrameAutosaveName("VerbatimCapsule")
            if !panel.setFrameUsingName("VerbatimCapsule") { placeDefault(panel) }
        }
        resize()
        panel?.orderFrontRegardless()
    }

    func showError(_ message: String) {
        state.error = message
        resize()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Keep the top-left corner fixed while the content grows or shrinks.
    func resize() {
        guard let panel, let host = panel.contentView else { return }
        DispatchQueue.main.async {
            let size = host.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            var frame = panel.frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - size.height
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    private func placeDefault(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        // Right edge, upper third: out of the way of most meeting windows.
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 68, y: visible.maxY - visible.height * 0.28))
    }
}

@Observable
final class PanelState {
    var error: String?
}
