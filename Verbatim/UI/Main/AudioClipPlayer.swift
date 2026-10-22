import AVFAudio
import Foundation
import Observation

/// Plays a slice of a recording's channel audio, so you can hear who is
/// talking before naming a speaker.
@Observable
final class AudioClipPlayer {
    private(set) var playingSegment: UUID?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(segment: Segment, in recording: Recording, url: URL) {
        if playingSegment == segment.id {
            stop()
            return
        }
        let start = recording.fileTime(segment.start, channel: segment.channel)
        play(url: url, from: start, duration: min(max(segment.end - segment.start, 2), 30), id: segment.id)
    }

    /// `start` is in the file's own time, not recording time.
    func play(url: URL, from start: TimeInterval, duration: TimeInterval, id: UUID) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        // A short lead-in so the first word isn't clipped.
        player.currentTime = max(0, start - 0.3)
        player.prepareToPlay()
        player.play()
        self.player = player
        playingSegment = id
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.6))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        player?.stop()
        player = nil
        playingSegment = nil
    }
}
