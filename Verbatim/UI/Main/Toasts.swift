import Observation
import SwiftUI

/// Short confirmations in the corner of the main window ("Saved to Notion",
/// "Couldn't export · Retry"). They stack, fan out on hover, and leave on
/// their own unless the pointer is resting on them.
@Observable
final class ToastCenter {
    struct Toast: Identifiable {
        enum Kind { case success, info, failure }
        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String?
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private(set) var toasts: [Toast] = []
    /// While hovered nothing expires, so a toast never vanishes under the pointer.
    var isHovered = false

    static let lifetime: Duration = .seconds(4.5)
    static let maxVisible = 3

    func show(_ kind: Toast.Kind, _ title: String, detail: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(kind: kind, title: title, detail: detail, actionTitle: actionTitle, action: action)
        toasts.append(toast)
        if toasts.count > Self.maxVisible { toasts.removeFirst(toasts.count - Self.maxVisible) }
        Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            while self?.isHovered == true { try? await Task.sleep(for: .milliseconds(400)) }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}

struct ToastStack: View {
    let center: ToastCenter
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardHeight: CGFloat = 56
    private let gap: CGFloat = 8

    var body: some View {
        let toasts = center.toasts
        let count = toasts.count
        ZStack(alignment: .bottom) {
            ForEach(Array(toasts.enumerated()), id: \.element.id) { index, toast in
                let depth = count - 1 - index // 0 is the newest, in front
                ToastCard(toast: toast) { center.dismiss(toast.id) }
                    .offset(y: expanded ? -CGFloat(depth) * (cardHeight + gap) : -CGFloat(depth) * 9)
                    .scaleEffect(expanded ? 1 : 1 - CGFloat(depth) * 0.05, anchor: .bottom)
                    .opacity(expanded ? 1 : 1 - Double(depth) * 0.18)
                    .zIndex(Double(index))
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 24).combined(with: .opacity),
                        removal: .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity)
                    ))
            }
        }
        // The hover area grows with the fanned-out stack, so it stays open
        // while the pointer moves up through it.
        .frame(width: 340, height: count == 0 ? 0 : (expanded ? CGFloat(count) * (cardHeight + gap) - gap : cardHeight + CGFloat(count - 1) * 9),
               alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { hovering in
            expanded = hovering && count > 1
            center.isHovered = hovering
        }
        .onChange(of: count) { if count <= 1 { expanded = false } }
        .animation(Theme.Motion.snappy(reduceMotion), value: expanded)
        .animation(Theme.Motion.snappy(reduceMotion), value: toasts.map(\.id))
        .padding(18)
    }
}

private struct ToastCard: View {
    let toast: ToastCenter.Toast
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(Theme.smallFont.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let detail = toast.detail {
                    Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action(); onClose() }.buttonStyle(.v(.secondary, .small))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 56)
        .raisedGlass(cornerRadius: Theme.radiusLarge)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
    }

    private var icon: String {
        switch toast.kind {
        case .success: "checkmark.circle"
        case .info: "info.circle"
        case .failure: "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: Theme.success
        case .info: Theme.textSecondary
        case .failure: Theme.recording
        }
    }
}
