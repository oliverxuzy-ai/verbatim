import Foundation
import UserNotifications

/// Watches the calendar and, when a meeting starts, either posts a
/// notification with a "Transcribe" button or (if enabled) starts recording
/// for meetings that have a video link.
final class MeetingReminder: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private var notified: Set<String> = []
    private var task: Task<Void, Never>?
    nonisolated private static let category = "dev.verbatim.meeting-start"
    nonisolated private static let transcribeAction = "dev.verbatim.transcribe"
    nonisolated private static let autoStopCategory = "dev.verbatim.auto-stop"
    nonisolated private static let keepRecordingAction = "dev.verbatim.keep-recording"
    nonisolated private static let autoStopID = "dev.verbatim.auto-stop"
    nonisolated private static let autoStoppedID = "dev.verbatim.auto-stopped"

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let transcribe = UNNotificationAction(identifier: Self.transcribeAction, title: "Transcribe", options: [.foreground])
        let keep = UNNotificationAction(identifier: Self.keepRecordingAction, title: "Keep recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [transcribe], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.autoStopCategory, actions: [keep], intentIdentifiers: []),
        ])
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func check() {
        guard let model, !model.isRecording else { return }
        let settings = model.settings
        guard settings.meetingReminders || settings.autoStartVideoMeetings else { return }
        let now = Date.now
        for meeting in model.calendar.events {
            guard let start = meeting.scheduledStart, let key = meeting.calendarEventID.map({ "\($0)@\(start.timeIntervalSince1970)" }),
                  !notified.contains(key),
                  start.addingTimeInterval(-60) <= now, now <= start.addingTimeInterval(5 * 60),
                  meeting.attendees.contains(where: { !$0.isSelf }) || meeting.looksOnline else { continue }
            notified.insert(key)
            if settings.autoStartVideoMeetings, meeting.looksOnline {
                model.startRecording(meeting: meeting)
                return
            }
            if settings.meetingReminders { post(meeting, key: key) }
        }
    }

    private func post(_ meeting: MeetingInfo, key: String) {
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        let others = meeting.attendees.filter { !$0.isSelf }.prefix(3).map(\.displayName)
        content.body = others.isEmpty ? "Starting now. Transcribe it?" : "Starting now with \(others.joined(separator: ", ")). Transcribe it?"
        content.categoryIdentifier = Self.category
        content.userInfo = ["key": key, "eventID": meeting.calendarEventID ?? ""]
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    // MARK: Auto-stop

    /// Warn that a recording that looks finished will stop in a minute, with
    /// a "Keep recording" button; nil withdraws the warning.
    func autoStopPending(_ reason: MeetingEndDetector.Reason?, title: String) {
        let center = UNUserNotificationCenter.current()
        guard let reason else {
            center.removeDeliveredNotifications(withIdentifiers: [Self.autoStopID])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Is \(title) over?"
        content.body = "\(reason.message) Verbatim will stop recording in 1 minute."
        content.categoryIdentifier = Self.autoStopCategory
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.autoStopID, content: content, trigger: nil))
    }

    func autoStopped(title: String, reason: MeetingEndDetector.Reason) {
        let content = UNMutableNotificationContent()
        content.title = "Stopped recording \(title)"
        content.body = "\(reason.message) The transcript is saved."
        content.sound = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.autoStopID])
        center.add(UNNotificationRequest(identifier: Self.autoStoppedID, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == Self.autoStopCategory {
            let keep = response.actionIdentifier == Self.keepRecordingAction
            await MainActor.run {
                guard let model = self.model else { return }
                if keep { model.session?.keepRecording() } else { model.windows.showMain() }
            }
            return
        }
        guard response.actionIdentifier == Self.transcribeAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let eventID = response.notification.request.content.userInfo["eventID"] as? String
        await MainActor.run {
            guard let model = self.model, !model.isRecording else { return }
            let meeting = model.calendar.events.first { $0.calendarEventID == eventID } ?? model.calendar.current
            if let meeting { model.startRecording(meeting: meeting) }
        }
    }
}
