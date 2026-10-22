import AppKit
import SwiftUI

// MARK: Buttons

struct VButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let size: Size
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(size == .small ? Theme.smallFont.weight(.medium) : Theme.bodyFont.weight(.medium))
                .padding(.horizontal, size == .small ? 10 : 14)
                .frame(height: size == .small ? 26 : 32)
                .foregroundStyle(foreground)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(border, lineWidth: Theme.hairline))
                .softShadow(kind == .secondary ? 1 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var foreground: Color {
            switch kind {
            case .primary: Theme.bg
            case .secondary, .ghost: Theme.text
            case .danger: .white
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? Theme.text.opacity(0.86) : Theme.text
            case .secondary: hovering ? Theme.surfaceRaised : Theme.surface
            case .ghost: hovering ? Theme.surfaceHover : .clear
            case .danger: hovering ? Theme.recording.opacity(0.86) : Theme.recording
            }
        }

        private var border: Color {
            switch kind {
            case .secondary: Theme.border
            default: .clear
            }
        }
    }
}

extension ButtonStyle where Self == VButtonStyle {
    static var vPrimary: VButtonStyle { VButtonStyle(kind: .primary) }
    static var vSecondary: VButtonStyle { VButtonStyle(kind: .secondary) }
    static var vGhost: VButtonStyle { VButtonStyle(kind: .ghost) }
    static var vDanger: VButtonStyle { VButtonStyle(kind: .danger) }
    static func v(_ kind: VButtonStyle.Kind, _ size: VButtonStyle.Size = .regular) -> VButtonStyle {
        VButtonStyle(kind: kind, size: size)
    }
}

/// Square icon button with hover background.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 26
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(hovering ? Theme.surfaceHover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: Surfaces

struct CardModifier: ViewModifier {
    var padding: CGFloat = 12
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
    }
}

extension View {
    func card(padding: CGFloat = 12, fill: Color = Theme.surface) -> some View {
        modifier(CardModifier(padding: padding, fill: fill))
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.border)
            .frame(width: vertical ? Theme.hairline : nil, height: vertical ? nil : Theme.hairline)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
    }
}

extension View {
    /// Two-layer soft shadow (contact + diffuse) for raised surfaces, Dia style.
    /// `strength` 0 removes it, so styles can toggle it without branching.
    func softShadow(_ strength: Double = 1) -> some View {
        shadow(color: .black.opacity(0.05 * strength), radius: 0.5, y: 0.5)
            .shadow(color: .black.opacity(0.06 * strength), radius: 8, y: 3)
    }

    /// A floating card of frosted paper over the window's content (toasts,
    /// the command bar): slightly translucent, with the same border and shadow.
    func raisedGlass(cornerRadius: CGFloat) -> some View {
        background(
            GlassBackground(material: .popover, blending: .withinWindow, tint: Theme.surface, opacity: 0.8)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
        .softShadow()
    }

    /// The raised white pill used for a selected sidebar item or a floating bar.
    func raisedPill(cornerRadius: CGFloat = 999) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
            .softShadow()
    }
}

/// The app's mark: three rounded bars, short, tall, short (same as the icon).
struct BrandMark: View {
    var height: CGFloat = 16
    var color: Color = Theme.text

    var body: some View {
        let width = height * 0.2
        HStack(spacing: height * 0.15) {
            Capsule().frame(width: width, height: height * 0.55)
            Capsule().frame(width: width, height: height)
            Capsule().frame(width: width, height: height * 0.55)
        }
        .foregroundStyle(color)
        .frame(height: height)
    }

    /// The same mark as a template image for the menu bar.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            let width: CGFloat = 3, gap: CGFloat = 2.4
            let heights: [CGFloat] = [7, 13, 7]
            var x = (rect.width - (3 * width + 2 * gap)) / 2
            for h in heights {
                NSBezierPath(roundedRect: NSRect(x: x, y: (rect.height - h) / 2, width: width, height: h), xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Initial in a speaker-coloured circle.
struct Avatar: View {
    let name: String
    let colorIndex: Int
    var size: CGFloat = 20

    var body: some View {
        let color = Theme.speakerColor(colorIndex)
        Text(String(name.trimmed.first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.textSecondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(Theme.captionFont.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: Recording visuals

/// Pulsing red recording dot.
struct RecordingDot: View {
    var size: CGFloat = 8
    var active = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.recording.opacity(active ? 0.25 : 0))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulse ? 1 : 0.4)
                .opacity(pulse ? 0 : 1)
            Circle().fill(active ? Theme.recording : Theme.textTertiary).frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Scrolling, mirrored bar waveform driven by real audio levels. Samples
/// arrive about 15 times a second; between them the bars glide left by one
/// step, so the strip moves continuously instead of ticking.
struct WaveformView: View {
    let levels: [Float]
    var color: Color = Theme.text
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 2
    var minHeight: CGFloat = 2
    private let interval = 1.0 / 15
    @State private var changedAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = min(1, timeline.date.timeIntervalSince(changedAt) / interval)
            let slide = CGFloat(1 - (1 - t) * (1 - t)) // ease out
            Canvas { context, size in
                let step = barWidth + spacing
                let count = max(1, Int((size.width + spacing) / step))
                // One extra bar on the left that slides out of view.
                let values = Array(levels.suffix(count + 1))
                let pad = count + 1 - values.count
                let offset = step * (1 - slide)
                for (i, value) in values.enumerated() {
                    let x = CGFloat(i + pad - 1) * step + offset
                    guard x > -step, x < size.width else { continue }
                    let h = max(minHeight, CGFloat(value) * size.height)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    // Older bars fade out slightly for a sense of motion.
                    let age = Double(i) / Double(max(1, values.count - 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(color.opacity(0.35 + 0.65 * age)))
                }
            }
        }
        .onChange(of: levels) { changedAt = .now }
    }
}

struct SpeakerBadge: View {
    let name: String
    let colorIndex: Int
    var confirmed = true

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.speakerColor(colorIndex)).frame(width: 7, height: 7)
            Text(name)
                .font(Theme.smallFont.weight(.semibold))
                .foregroundStyle(Theme.speakerColor(colorIndex))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !confirmed {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Suggested speaker. Click the speaker chip above to confirm or rename.")
            }
        }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.serifSmallFont).foregroundStyle(Theme.text)
            Text(message).font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Date {
    var timeString: String {
        formatted(date: .omitted, time: .shortened)
    }

    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        return formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
