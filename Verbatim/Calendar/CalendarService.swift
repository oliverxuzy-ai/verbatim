import AppKit
import EventKit
import Foundation
import Observation

/// Meetings for the picker, reminders and recordings. Signed in to Google,
/// they come straight from Google Calendar; otherwise from macOS Calendar
/// (EventKit), which is only used if the user allowed it.
@Observable
final class CalendarService {
    nonisolated struct CalendarSource: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let account: String
        let colorHex: String
    }

    enum Access: Equatable {
        case unknown, granted, denied
    }

    private(set) var access: Access = .unknown
    private(set) var events: [MeetingInfo] = []
    private(set) var calendars: [CalendarSource] = []
    private(set) var lastRefresh: Date?

    let google: GoogleAuth
    private(set) var googleError: String?
    private var googleFetch: Task<Void, Never>?

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    var hiddenCalendarIDs: Set<String> = []

    init(google: GoogleAuth = GoogleAuth()) {
        self.google = google
        updateAccessFromStatus()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func updateAccessFromStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    func requestAccess() async {
        do {
            let ok = try await store.requestFullAccessToEvents()
            access = ok ? .granted : .denied
        } catch {
            Log.calendar.error("Calendar access failed: \(error.localizedDescription)")
            access = .denied
        }
        if access == .granted {
            store.refreshSourcesIfNecessary()
            refresh()
        }
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    #if true // Self-check support: a temporary event on a writable calendar.
    /// Creates a short event happening now on the first writable calendar of
    /// an account whose name matches `account`; returns its identifier.
    func createTemporaryEvent(title: String, link: URL, account: String) throws -> String? {
        guard access == .granted else { return nil }
        let calendars = store.calendars(for: .event).filter { $0.allowsContentModifications && ($0.source?.title ?? "").contains(account) }
        guard let calendar = calendars.first(where: { $0.title == "Adhoc" }) ?? calendars.first else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        // Started 6 minutes ago: still "now" in the picker, but past the
        // meeting-start reminder window, so no notification goes out.
        event.startDate = Date.now.addingTimeInterval(-360)
        event.endDate = Date.now.addingTimeInterval(20 * 60)
        event.url = link
        event.location = link.absoluteString
        event.notes = "Created by the Verbatim self check and deleted automatically."
        event.alarms = []
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    /// Ask macOS to pull fresh data from Google / iCloud now.
    func refreshRemoteSources() {
        store.refreshSourcesIfNecessary()
    }

    func deleteEvent(_ identifier: String) throws {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }
    #endif

    /// Wider read for diagnostics: every meeting in [now - days, now + days].
    func meetings(withinDays days: Int) -> [(meeting: MeetingInfo, calendar: String, account: String)] {
        guard access == .granted else { return [] }
        let start = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let end = Date.now.addingTimeInterval(Double(days) * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: store.calendars(for: .event))
        return store.events(matching: predicate).filter { !$0.isAllDay }.map {
            (Self.meeting(from: $0), $0.calendar?.title ?? "", $0.calendar?.source?.title ?? "")
        }
    }

    /// A calendar is connected: Google, or macOS Calendar with access.
    var isConnected: Bool { google.isSignedIn || access == .granted }

    func connectGoogle() async {
        await google.signIn()
        guard google.isSignedIn else { return }
        events = []
        refresh()
    }

    func disconnectGoogle() async {
        await google.signOut()
        events = []
        googleError = nil
        refresh()
    }

    func refresh() {
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") { return }
        #endif
        if google.isSignedIn {
            refreshGoogle()
            return
        }
        updateAccessFromStatus()
        guard access == .granted else { return }
        let cals = store.calendars(for: .event)
        calendars = cals.map {
            CalendarSource(
                id: $0.calendarIdentifier,
                title: $0.title,
                account: $0.source?.title ?? "",
                colorHex: $0.cgColor.flatMap(Self.hex) ?? "#888888"
            )
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }

        let visible = cals.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else { events = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now).addingTimeInterval(-24 * 3600)
        let end = cal.startOfDay(for: .now).addingTimeInterval(3 * 24 * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: visible)
        let ekEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .filter { event in
                // Drop events the user declined.
                guard let me = event.attendees?.first(where: \.isCurrentUser) else { return true }
                return me.participantStatus != .declined
            }
        events = ekEvents.map(Self.meeting(from:)).sorted { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) }
        lastRefresh = .now
    }

    /// Same window as macOS Calendar: yesterday through the day after tomorrow.
    private func refreshGoogle() {
        guard googleFetch == nil else { return }
        let day = Calendar.current.startOfDay(for: .now)
        let start = day.addingTimeInterval(-24 * 3600)
        let end = day.addingTimeInterval(3 * 24 * 3600)
        googleFetch = Task {
            defer { googleFetch = nil }
            do {
                let meetings: [MeetingInfo]
                do {
                    meetings = try await GoogleCalendarAPI.meetings(accessToken: try await google.accessToken(), from: start, to: end)
                } catch GoogleCalendarAPI.APIError.unauthorized {
                    // Revoked or rotated early: get a fresh token once.
                    google.discardAccessToken()
                    meetings = try await GoogleCalendarAPI.meetings(accessToken: try await google.accessToken(), from: start, to: end)
                }
                guard google.isSignedIn else { return }
                events = meetings.sorted { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) }
                lastRefresh = .now
                googleError = nil
            } catch {
                googleError = error.localizedDescription
                Log.calendar.error("Google Calendar refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// Meetings relevant for "pick one to record": in progress now, then the
    /// rest of today, then tomorrow.
    var upcoming: [MeetingInfo] {
        let now = Date.now
        let endOfTomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(2 * 24 * 3600)
        return events.filter {
            guard let s = $0.scheduledStart, let e = $0.scheduledEnd else { return false }
            return e > now.addingTimeInterval(-15 * 60) && s < endOfTomorrow
        }
    }

    var current: MeetingInfo? {
        let now = Date.now
        return events.first {
            guard let s = $0.scheduledStart, let e = $0.scheduledEnd else { return false }
            return s.addingTimeInterval(-5 * 60) <= now && now < e
        }
    }

    #if DEBUG
    func debugSetEvents(_ events: [MeetingInfo]) {
        self.events = events
        access = .granted
    }
    #endif

    /// True when macOS Calendar is the source but nothing in the next days
    /// looks like a meeting (no attendees or video link): usually the work
    /// account isn't there, and connecting Google directly fixes it.
    var looksDisconnected: Bool {
        !google.isSignedIn && access == .granted && !upcoming.contains { $0.attendees.count > 1 || $0.looksOnline }
    }

    // MARK: Mapping

    nonisolated static func meeting(from event: EKEvent) -> MeetingInfo {
        var attendees: [Attendee] = (event.attendees ?? []).compactMap { p in
            guard p.participantType != .room, p.participantType != .resource else { return nil }
            let email = p.url.absoluteString.hasPrefix("mailto:")
                ? String(p.url.absoluteString.dropFirst("mailto:".count)).removingPercentEncoding
                : nil
            return Attendee(
                name: p.name ?? email ?? "",
                email: email,
                isSelf: p.isCurrentUser,
                isOrganizer: p.participantRole == .chair
            )
        }
        if let organizer = event.organizer, !attendees.contains(where: { $0.isOrganizer }) {
            let email = organizer.url.absoluteString.hasPrefix("mailto:")
                ? String(organizer.url.absoluteString.dropFirst("mailto:".count)) : nil
            if !attendees.contains(where: { $0.email != nil && $0.email == email }) {
                attendees.append(Attendee(name: organizer.name ?? email ?? "", email: email,
                                          isSelf: organizer.isCurrentUser, isOrganizer: true))
            }
        }
        return MeetingInfo(
            calendarEventID: event.calendarItemExternalIdentifier ?? event.eventIdentifier,
            title: (event.title ?? "").trimmed.isEmpty ? "Untitled event" : event.title!.trimmed,
            scheduledStart: event.startDate,
            scheduledEnd: event.endDate,
            attendees: attendees,
            conferenceURL: conferenceURL(for: event),
            calendarName: event.calendar?.title,
            location: event.location
        )
    }

    /// Find the video call link: explicit URL, then location, then notes.
    nonisolated static func conferenceURL(for event: EKEvent) -> URL? {
        if let url = event.url, ConferenceProvider.detect(url.absoluteString) != nil { return url }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = firstConferenceLink(in: text) { return url }
        }
        return event.url
    }

    nonisolated static func firstConferenceLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let urls = matches.compactMap(\.url)
        return urls.first { ConferenceProvider.detect($0.absoluteString) != nil }
    }

    nonisolated private static func hex(_ color: CGColor) -> String? {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
    }
}
