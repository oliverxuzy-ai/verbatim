import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecordingDetailView: View {
    let model: AppModel
    let recordingID: UUID
    @State private var player = AudioClipPlayer()
    @State private var editingTitle: UUID?
    @State private var titleDraft = ""
    @State private var hoveringTitle = false
    @FocusState private var titleFocused: Bool
    @State private var followLive = true
    @State private var resolving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingSpeaker: String?
    @State private var copied = false

    private var recording: Recording? { model.recording(recordingID) }
    private var isLive: Bool { model.session?.recordingID == recordingID && model.session?.isActive == true }

    var body: some View {
        if let recording {
            VStack(spacing: 0) {
                topBar(recording)
                transcript(recording)
            }
            .background(Theme.bg)
            .onDisappear { player.stop() }
            // The refined transcript resolves into place, like a picture
            // sharpening under glass, so the update is visible.
            .onChange(of: recording.refinedAt) { old, new in
                guard new != nil, new != old, !reduceMotion else { return }
                resolving = true
                DispatchQueue.main.async { resolving = false }
            }
        }
    }

    // MARK: Top bar

    /// Breadcrumb on the left, the actions (or live controls) on the right.
    private func topBar(_ rec: Recording) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button("Today") { model.selectedRecordingID = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text(rec.meeting.title).foregroundStyle(Theme.text).lineLimit(1)
            }
            .font(Theme.smallFont)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.surface.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.hairline))
            .layoutPriority(-1)
            Spacer(minLength: 8)
            if !isLive {
                actions(rec)
            } else if let session = model.session, session.phase == .stopping {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finishing…").font(Theme.smallFont).foregroundStyle(Theme.textSecondary)
                }
            } else if let session = model.session {
                HStack(spacing: 8) {
                    Button { session.togglePause() } label: {
                        Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.vSecondary)
                    Button { model.stopRecording() } label: { Label("Stop and save", systemImage: "stop.fill") }
                        .buttonStyle(.vDanger)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44) // centred on the traffic lights' line
    }

    // MARK: Header

    private func header(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // One click to rename: Return or clicking elsewhere saves, Esc cancels.
            if editingTitle == recordingID {
                TextField("Meeting title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.serifTitleFont)
                    .foregroundStyle(Theme.text)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onExitCommand { editingTitle = nil }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                    .onAppear { titleFocused = true }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(rec.meeting.title)
                        .font(Theme.serifTitleFont)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .opacity(hoveringTitle ? 1 : 0)
                }
                .contentShape(Rectangle())
                .pointerStyle(.horizontalText)
                .onHover { hoveringTitle = $0 }
                .onTapGesture {
                    titleDraft = rec.meeting.title
                    editingTitle = recordingID
                }
                .help("Click to rename")
            }
            // One line always: drop language and engine when the column is
            // narrow instead of wrapping words onto a second line.
            ViewThatFits(in: .horizontal) {
                meta(rec, compact: false)
                meta(rec, compact: true).lineLimit(1)
            }
            .font(Theme.smallFont)
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dot: some View { Text("·").foregroundStyle(Theme.textTertiary) }

    /// Saves to the recording the edit started on, even if the selection
    /// moved meanwhile; an empty title keeps the old one.
    private func commitTitle() {
        guard let id = editingTitle else { return }
        editingTitle = nil
        model.renameRecording(id, title: titleDraft)
    }

    private func meta(_ rec: Recording, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text(rec.startedAt.formatted(date: .abbreviated, time: .shortened))
            dot
            if isLive {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(rec.duration.shortClockString).monospacedDigit().foregroundStyle(Theme.recording)
                        .contentTransition(.numericText())
                }
            } else {
                Text(rec.duration.shortClockString).monospacedDigit()
            }
            if !compact {
                dot
                Text(LanguageOption.label(for: rec.language))
                dot
                Text(EngineKind(rawValue: rec.engine)?.label ?? rec.engine)
            }
            if let provider = rec.meeting.conferenceProvider {
                dot
                Text(provider.label)
            }
            refineStatus(rec)
        }
    }

    /// Visible progress after a meeting ends: what is being done right now.
    @ViewBuilder
    private func processingBanner(_ rec: Recording) -> some View {
        if case let .running(message) = model.refineStates[rec.id] {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recording saved. \(message)")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("Export now or wait for the refined version.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        } else if case let .failed(message) = model.refineStates[rec.id] {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text("Refine didn't finish: \(message) The live transcript is kept.")
                    .font(Theme.smallFont).foregroundStyle(Theme.text)
                Spacer()
                Button("Try again") { Task { await model.refine(rec.id) } }.buttonStyle(.v(.secondary, .small))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func liveWarnings() -> some View {
        if isLive, let warnings = model.session?.warnings, !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.smallFont).foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func refineStatus(_ rec: Recording) -> some View {
        switch model.refineStates[rec.id] {
        case let .running(message):
            dot
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(message)
            }
            .foregroundStyle(Theme.accent)
        case let .failed(message):
            dot
            Label("Refine failed", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).help(message)
        default:
            if rec.refinedAt != nil {
                dot
                Label("Refined", systemImage: "sparkles").foregroundStyle(Theme.textSecondary)
                    .help("Re-transcribed from the full recording with whole-meeting speaker separation")
            }
        }
    }

    @ViewBuilder
    private func actions(_ rec: Recording) -> some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TranscriptFormatter.plainText(rec), forType: .string)
                withAnimation(Theme.Motion.snappy) { copied = true }
                model.toasts.show(.success, "Transcript copied", detail: "\(rec.visibleSegments.count) lines with timestamps and speakers")
                Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation(Theme.Motion.snappy) { copied = false } }
            } label: {
                Label {
                    Text(copied ? "Copied" : "Copy")
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.vSecondary)

            exportButton(rec)

            Menu {
                if model.canRefine(rec) {
                    Button(rec.refinedAt == nil ? "Refine transcript" : "Refine again") { Task { await model.refine(rec.id) } }
                }
                if model.settings.hasAnthropicKey {
                    Button("Suggest speaker names with Claude") { Task { await model.suggestNames(rec.id) } }
                }
                Divider()
                Button("Export Markdown…") { saveMarkdown(rec) }
                Button("Show audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.folder(for: rec.id)])
                }
                if rec.notionPageURL != nil {
                    Button("Export to Notion again") { Task { await model.export(rec.id) } }
                }
                Divider()
                Button("Delete recording", role: .destructive) { model.deleteRecording(rec.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 32, height: 32)
            .background(Theme.surface, in: Circle())
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: Theme.hairline))
        }
    }

    @ViewBuilder
    private func exportButton(_ rec: Recording) -> some View {
        switch model.exportState(rec.id) {
        case .idle:
            Button {
                Task { await model.export(rec.id) }
            } label: {
                Label("Export to Notion", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.vPrimary)
            .help(unconfirmedCount(rec) > 0 ? "\(unconfirmedCount(rec)) speaker(s) not confirmed yet" : "Save the transcript to Meeting Transcripts")
        case .exporting:
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Exporting…") }
            }
            .buttonStyle(.vPrimary)
            .disabled(true)
        case let .done(url):
            Button { model.openInNotion(url) } label: {
                Label("Open in Notion", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.vSecondary)
        case let .failed(message):
            Button {
                Task { await model.export(rec.id) }
            } label: {
                Label("Retry export", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.vSecondary)
            .help(message)
            .popoverTip(message)
        }
    }

    private func unconfirmedCount(_ rec: Recording) -> Int {
        let used = Set(rec.visibleSegments.map(\.speakerID))
        return rec.speakers.filter { used.contains($0.id) && !$0.isConfirmed }.count
    }

    private func saveMarkdown(_ rec: Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = rec.meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? TranscriptFormatter.markdown(rec).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Speakers

    private func speakerBar(_ rec: Recording) -> some View {
        let counts = Dictionary(grouping: rec.visibleSegments, by: \.speakerID).mapValues(\.count)
        let speakers = rec.speakers.filter { counts[$0.id] != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if speakers.isEmpty {
                    Text(isLive ? "Waiting for speech…" : "No speech detected")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                ForEach(speakers) { speaker in
                    SpeakerChip(speaker: speaker, count: counts[speaker.id] ?? 0) {
                        editingSpeaker = speaker.id
                    }
                    .popover(isPresented: Binding(
                        get: { editingSpeaker == speaker.id },
                        set: { if !$0 { editingSpeaker = nil } }
                    ), arrowEdge: .bottom) {
                        SpeakerEditor(model: model, recordingID: recordingID, speaker: speaker, player: player) {
                            editingSpeaker = nil
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Transcript

    private func transcript(_ rec: Recording) -> some View {
        let segments = rec.visibleSegments
        let volatile = isLive ? Array(model.session?.transcript.volatile.values ?? [:].values).sorted { $0.start < $1.start } : []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(rec).padding(.bottom, 14)
                    VStack(alignment: .leading, spacing: 8) {
                        liveWarnings()
                        processingBanner(rec)
                    }
                    speakerBar(rec).padding(.top, 6).padding(.bottom, 18)
                    if segments.isEmpty && volatile.isEmpty {
                        EmptyStateView(
                            systemImage: isLive ? "waveform" : "text.bubble",
                            title: isLive ? "Listening…" : "Empty transcript",
                            message: isLive ? "Lines appear here as people speak." : "No speech was recognized in this recording."
                        )
                        .frame(height: 240)
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        TranscriptRow(
                            model: model, recordingID: recordingID, recording: rec, segment: segment,
                            isPlaying: player.playingSegment == segment.id,
                            showSpeaker: showSpeaker(segment, in: segments)
                        ) {
                            player.toggle(segment: segment, in: rec, url: model.store.audioURL(for: rec.id, channel: segment.channel))
                        }
                        .id(segment.id)
                        .modifier(Resolve(active: resolving, delay: min(Double(index) * 0.035, 0.9)))
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    ForEach(volatile) { segment in
                        TranscriptRow(model: model, recordingID: recordingID, recording: rec, segment: segment,
                                      isPlaying: false, showSpeaker: true) {}
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 40).id("bottom")
                }
                .animation(.easeOut(duration: 0.25), value: segments.count)
                .padding(.horizontal, 40)
                .padding(.top, 18)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, atBottom in
                followLive = atBottom
            }
            .onChange(of: segments.count) {
                if isLive && followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: volatile.map(\.text)) {
                if isLive && followLive { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if isLive && !followLive {
                    Button {
                        followLive = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Jump to live", systemImage: "arrow.down")
                    }
                    .buttonStyle(.v(.secondary, .small))
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: followLive)
        }
    }

    private func showSpeaker(_ segment: Segment, in segments: [Segment]) -> Bool {
        guard let i = segments.firstIndex(of: segment), i > 0 else { return true }
        let prev = segments[i - 1]
        return prev.speakerID != segment.speakerID || segment.start - prev.end > 30
    }
}

/// Blurred and faint while `active`; eases back to sharp after `delay`
/// when it clears, so a list resolves from top to bottom.
private struct Resolve: ViewModifier {
    let active: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 7 : 0)
            .opacity(active ? 0.3 : 1)
            .animation(active ? nil : .easeOut(duration: 0.7).delay(delay), value: active)
    }
}

private struct SpeakerChip: View {
    let speaker: Speaker
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Avatar(name: speaker.name, colorIndex: speaker.colorIndex, size: 18)
                Text(speaker.name).font(Theme.smallFont.weight(.medium)).foregroundStyle(Theme.text)
                if speaker.isMe { Text("you").font(Theme.captionFont).foregroundStyle(Theme.textTertiary) }
                if !speaker.isConfirmed {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
                Text("\(count)").font(Theme.monoSmallFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(hovering ? Theme.surfaceRaised : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(speaker.isConfirmed ? Theme.border : Theme.warning.opacity(0.45), lineWidth: Theme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(speaker.isConfirmed ? "Rename or merge" : "Not confirmed: click to choose who this is")
    }
}

private struct TranscriptRow: View {
    let model: AppModel
    let recordingID: UUID
    let recording: Recording
    let segment: Segment
    let isPlaying: Bool
    let showSpeaker: Bool
    let onPlay: () -> Void
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let speaker = recording.speaker(segment.speakerID)
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                if showSpeaker {
                    Menu {
                        ForEach(recording.speakers) { s in
                            Button(s.name) { model.reassignSegment(recordingID: recordingID, segmentID: segment.id, to: s.id) }
                        }
                    } label: {
                        SpeakerBadge(name: speaker?.name ?? "Unknown", colorIndex: speaker?.colorIndex ?? 0, confirmed: speaker?.isConfirmed ?? true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 124, alignment: .leading)
                    .disabled(!segment.isFinal)
                    .help("Assign this line to a different speaker")
                }
                Button(action: onPlay) {
                    HStack(spacing: 3) {
                        Text(segment.start.clockString)
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 7))
                            .opacity(hovering || isPlaying ? 1 : 0)
                    }
                    .font(Theme.monoSmallFont)
                    .foregroundStyle(isPlaying ? Theme.accent : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!segment.isFinal)
                .help("Play this part")
            }
            .frame(width: 124, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextEditor(text: $draft)
                        .font(Theme.readingFont)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44)
                        .padding(4)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.accent.opacity(0.6)))
                    HStack {
                        Button("Save") {
                            model.updateSegmentText(recordingID: recordingID, segmentID: segment.id, text: draft.trimmed)
                            editing = false
                        }
                        .buttonStyle(.v(.primary, .small))
                        .keyboardShortcut(.return, modifiers: .command)
                        Button("Cancel") { editing = false }.buttonStyle(.v(.ghost, .small))
                    }
                } else {
                    Text(segment.text)
                        .font(Theme.readingFont)
                        .lineSpacing(4)
                        .foregroundStyle(segment.isFinal ? Theme.text : Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, showSpeaker ? 12 : 4)
        .padding(.bottom, 4)
        .padding(.horizontal, 8)
        .background(hovering && segment.isFinal ? Theme.surfaceHover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .onHover { hovering = $0 }
        .contextMenu {
            if segment.isFinal {
                Button("Edit text") { draft = segment.text; editing = true }
                Button("Copy line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("[\(segment.start.clockString)] \(speaker?.name ?? ""): \(segment.text)", forType: .string)
                }
            }
        }
    }
}

extension View {
    /// Small helper to surface an error message as a tooltip popover.
    func popoverTip(_ message: String) -> some View { help(message) }
}
