import SwiftUI

/// "Who is this?" popover: listen to a sample, pick an attendee from the
/// calendar invite, type a name, or merge with another speaker.
struct SpeakerEditor: View {
    let model: AppModel
    let recordingID: UUID
    let speaker: Speaker
    let player: AudioClipPlayer
    let done: () -> Void
    @State private var name = ""

    private var recording: Recording? { model.recording(recordingID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Who is this?").font(Theme.headingFont).foregroundStyle(Theme.text)
                Spacer()
                if let sample = sampleSegment, let recording {
                    Button {
                        player.toggle(segment: sample, in: recording, url: model.store.audioURL(for: recordingID, channel: sample.channel))
                    } label: {
                        Label(player.playingSegment == sample.id ? "Stop" : "Play sample",
                              systemImage: player.playingSegment == sample.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.v(.secondary, .small))
                }
            }
            if let sample = sampleSegment {
                Text("\u{201C}\(sample.text.prefix(140))\(sample.text.count > 140 ? "…" : "")\u{201D}")
                    .font(Theme.smallFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).buttonStyle(.v(.primary, .small))
            }

            let attendees = (recording?.meeting.attendees ?? []).filter { !$0.isSelf }
            if !attendees.isEmpty {
                SectionLabel("From the invite")
                FlowLayout(spacing: 6) {
                    ForEach(attendees, id: \.self) { a in
                        Button(a.displayName) {
                            model.updateSpeaker(recordingID: recordingID, speakerID: speaker.id, name: a.displayName, email: a.email)
                            done()
                        }
                        .buttonStyle(.v(.secondary, .small))
                        .help(a.email ?? "")
                    }
                }
            }

            HStack(spacing: 6) {
                Button("This is me") {
                    model.updateSpeaker(recordingID: recordingID, speakerID: speaker.id, name: model.settings.myName, email: nil, isMe: true)
                    done()
                }
                .buttonStyle(.v(.ghost, .small))
                let others = (recording?.speakers ?? []).filter { $0.id != speaker.id }
                if !others.isEmpty {
                    Menu("Merge into…") {
                        ForEach(others) { other in
                            Button(other.name) {
                                model.mergeSpeaker(recordingID: recordingID, from: speaker.id, into: other.id)
                                done()
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(Theme.smallFont)
                    .help("Same person split into two speakers? Merge them.")
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { name = speaker.name }
    }

    /// A representative clip: the longest line, preferring 3–15 s.
    private var sampleSegment: Segment? {
        let mine = (recording?.visibleSegments ?? []).filter { $0.speakerID == speaker.id }
        let good = mine.filter { $0.end - $0.start >= 3 && $0.end - $0.start <= 15 }
        return (good.isEmpty ? mine : good).max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    private func save() {
        let email = recording?.meeting.attendees.first { $0.displayName == name.trimmed }?.email
        model.updateSpeaker(recordingID: recordingID, speakerID: speaker.id, name: name, email: email)
        done()
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
