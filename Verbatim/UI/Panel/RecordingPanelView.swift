import SwiftUI

/// Vertical capsule shown while recording: app mark (opens the live
/// transcript), a small voice-print that moves with the audio, pause, stop.
/// Deliberately tiny; the transcript itself lives in the main window.
struct RecordingPanelView: View {
    let model: AppModel
    @Bindable var state: PanelState
    let onLayoutChange: () -> Void

    var body: some View {
        Group {
            if let error = state.error {
                errorCard(error)
            } else {
                capsule
            }
        }
        .padding(Layout.inset) // room for the shadow inside the borderless window
        .onChange(of: state.error) { onLayoutChange() }
        .onChange(of: model.session?.autoStopSecondsLeft == nil) { onLayoutChange() }
    }

    // MARK: Capsule

    /// Sizes shared with the self check, which clicks these buttons.
    enum Layout {
        static let width: CGFloat = 44
        static let inset: CGFloat = 6        // room for the shadow inside the window
        static let verticalPadding: CGFloat = 10
        static let button: CGFloat = 30
        static let spacing: CGFloat = 8
        /// Centres measured up from the window's bottom edge.
        static let stopCenterFromBottom = inset + verticalPadding + button / 2
        static let pauseCenterFromBottom = stopCenterFromBottom + button + spacing
    }

    private var capsule: some View {
        let session = model.session
        let phase = session?.phase
        let paused = session?.isPaused ?? false
        return VStack(spacing: Layout.spacing) {
            // The meeting looks over: count down, click to keep recording.
            if let left = session?.autoStopSecondsLeft {
                Button { session?.keepRecording() } label: {
                    Text("\(left)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.warning)
                        .frame(width: Layout.button, height: Layout.button)
                        .background(Theme.warning.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(session?.autoStopReason?.message ?? "The meeting seems to be over.") Recording stops in \(left) s. Click to keep recording.")
                .transition(.opacity)
            }

            // The voice-print is the handle: click it for the live transcript.
            Button {
                if let id = session?.recordingID { model.selectedRecordingID = id }
                model.windows.showMain()
            } label: {
                Group {
                    switch phase {
                    case .recording:
                        VoicePrint(levels: session?.levelHistory ?? [], paused: paused)
                    case .preparing, .stopping, .none:
                        ProgressView().controlSize(.small)
                    default:
                        VoicePrint(levels: [], paused: true)
                    }
                }
                .frame(width: 24, height: 40)
                .overlay(alignment: .topTrailing) {
                    if session?.systemAudioOK == false {
                        Circle().fill(Theme.warning).frame(width: 7, height: 7).offset(x: 5, y: -4)
                    }
                }
                .frame(width: Layout.button, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText(session))

            CapsuleButton(
                systemName: paused ? "play.fill" : "pause.fill",
                foreground: Theme.text,
                background: Theme.surfaceRaised,
                help: paused ? "Resume" : "Pause"
            ) {
                session?.togglePause()
            }
            .disabled(phase != .recording)

            CapsuleButton(
                systemName: "stop.fill",
                foreground: Theme.recording,
                background: Theme.recording.opacity(0.12),
                help: "Stop and save"
            ) {
                model.stopRecording()
            }
            .disabled(phase == .stopping || session == nil)
        }
        .padding(.vertical, Layout.verticalPadding)
        .frame(width: Layout.width)
        .background(
            GlassBackground(material: .popover, tint: Theme.surface, opacity: 0.72)
                .clipShape(Capsule(style: .continuous))
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
        .softShadow()
    }

    private func helpText(_ session: RecordingSession?) -> String {
        guard let session else { return "Verbatim" }
        let title = session.transcript.recording.meeting.title
        switch session.phase {
        case let .preparing(message): return "\(title)\n\(message)"
        case .recording:
            let warning = session.systemAudioOK ? "" : "\nCall audio isn't being captured. Click for details."
            return "\(title) · \(session.elapsed.shortClockString)\(session.isPaused ? " · paused" : "")\nClick to open the live transcript\(warning)"
        case .stopping: return "Saving…"
        default: return title
        }
    }

    // MARK: Error

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.recording)
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't start recording").font(Theme.smallFont.weight(.semibold)).foregroundStyle(Theme.text)
                Text(message).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Settings") { model.windows.showSettings(); model.panel.hide() }
                        .buttonStyle(.v(.secondary, .small))
                    Button("Dismiss") { model.panel.hide() }
                        .buttonStyle(.v(.ghost, .small))
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// A column of short horizontal dashes whose widths follow the recent audio
/// level, newest in the middle, like a vertical voice-print. Drawn in one
/// Canvas pass so a 15 Hz level feed stays cheap.
struct VoicePrint: View {
    let levels: [Float]
    var paused = false
    private let rows = 7
    /// Levels arrive about 15 times a second; each row eases to its new
    /// width over one interval instead of jumping.
    private let interval = 1.0 / 15
    @State private var previous: [Float] = []
    @State private var changedAt = Date.distantPast

    var body: some View {
        let current = Array(levels.suffix(rows))
        let active = Theme.textSecondary
        let idle = Theme.textTertiary
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
            let t = min(1, timeline.date.timeIntervalSince(changedAt) / interval)
            let eased = Float(1 - pow(1 - t, 3))
            let shown = previous.count == current.count
                ? zip(previous, current).map { $0 + ($1 - $0) * eased }
                : current
            Canvas { context, size in
                let rowHeight: CGFloat = 3
                let gap = (size.height - CGFloat(rows) * rowHeight) / CGFloat(rows - 1)
                for i in 0..<rows {
                    let v = paused ? 0 : CGFloat(value(at: i, shown))
                    let width = 4 + v * (size.width - 4)
                    let rect = CGRect(x: (size.width - width) / 2, y: CGFloat(i) * (rowHeight + gap), width: width, height: rowHeight)
                    let color = paused ? idle : active.opacity(0.55 + 0.45 * v)
                    context.fill(Path(roundedRect: rect, cornerRadius: rowHeight / 2), with: .color(color))
                }
            }
        }
        .onChange(of: levels) { old, _ in
            previous = Array(old.suffix(rows))
            changedAt = .now
        }
    }

    /// Spread the most recent samples symmetrically around the centre row.
    private func value(at row: Int, _ recent: [Float]) -> Float {
        guard !recent.isEmpty else { return 0 }
        let distance = abs(row - rows / 2)
        let index = max(0, recent.count - 1 - distance)
        let falloff: Float = 1 - Float(distance) * 0.12
        return min(1, recent[index] * falloff * 1.3)
    }
}

private struct CapsuleButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: RecordingPanelView.Layout.button, height: RecordingPanelView.Layout.button)
                .background(background.opacity(hovering ? 1 : 0.85), in: Circle())
                .scaleEffect(hovering ? 1.05 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
