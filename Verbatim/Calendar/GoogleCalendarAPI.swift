import Foundation

/// Reads meetings from the signed-in user's primary Google Calendar
/// (Calendar API v3, events.list), the calendar invites land on.
nonisolated enum GoogleCalendarAPI {
    enum APIError: LocalizedError {
        case unauthorized
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Google rejected the sign-in token."
            case let .http(status, message): "Google Calendar error \(status): \(message)"
            }
        }
    }

    static let eventsURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

    static func meetings(accessToken: String, from start: Date, to end: Date) async throws -> [MeetingInfo] {
        let rfc3339 = ISO8601DateFormatter()
        var meetings: [MeetingInfo] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(url: eventsURL, resolvingAgainstBaseURL: false)!
            c.queryItems = [
                URLQueryItem(name: "timeMin", value: rfc3339.string(from: start)),
                URLQueryItem(name: "timeMax", value: rfc3339.string(from: end)),
                URLQueryItem(name: "singleEvents", value: "true"), // recurring meetings as instances
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: c.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw APIError.unauthorized }
            guard (200..<300).contains(status) else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
                throw APIError.http(status, message)
            }
            let page = try parse(data)
            meetings += page.meetings
            pageToken = page.nextPageToken
        } while pageToken != nil
        return meetings
    }

    static func parse(_ data: Data) throws -> (meetings: [MeetingInfo], nextPageToken: String?) {
        let page = try JSONDecoder().decode(EventsPage.self, from: data)
        return ((page.items ?? []).compactMap(meeting(from:)), page.nextPageToken)
    }

    /// nil for things that aren't meetings: cancelled, declined, all-day,
    /// working location, out of office, focus time, birthdays.
    static func meeting(from event: Event) -> MeetingInfo? {
        guard event.status != "cancelled",
              !["workingLocation", "outOfOffice", "focusTime", "birthday"].contains(event.eventType ?? "default"),
              let start = event.start?.dateTime.flatMap(parseDate), let end = event.end?.dateTime.flatMap(parseDate) else { return nil }
        let people = (event.attendees ?? []).filter { $0.resource != true } // rooms are not people
        if people.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) { return nil }
        var attendees = people.map {
            Attendee(name: $0.displayName ?? "", email: $0.email, isSelf: $0.isSelf == true, isOrganizer: $0.organizer == true)
        }
        if attendees.isEmpty, let organizer = event.organizer {
            attendees = [Attendee(name: organizer.displayName ?? "", email: organizer.email,
                                  isSelf: organizer.isSelf == true, isOrganizer: true)]
        }
        let title = (event.summary ?? "").trimmed
        return MeetingInfo(
            calendarEventID: event.id,
            title: title.isEmpty ? "Untitled event" : title,
            scheduledStart: start,
            scheduledEnd: end,
            attendees: attendees,
            conferenceURL: conferenceURL(for: event),
            calendarName: "Google Calendar",
            location: event.location
        )
    }

    /// Meet link first, then any video entry point, then a Zoom / Teams / …
    /// link in the location or description.
    static func conferenceURL(for event: Event) -> URL? {
        if let link = event.hangoutLink, let url = URL(string: link) { return url }
        if let video = event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
           let url = URL(string: video) { return url }
        for text in [event.location, event.description].compactMap({ $0 }) {
            if let url = CalendarService.firstConferenceLink(in: text) { return url }
        }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    // MARK: Wire format (only the fields used)

    struct EventsPage: Decodable {
        var items: [Event]?
        var nextPageToken: String?
    }

    struct Event: Decodable {
        var id: String?
        var status: String?
        var summary: String?
        var description: String?
        var location: String?
        var start: Time?
        var end: Time?
        var attendees: [Person]?
        var organizer: Person?
        var hangoutLink: String?
        var conferenceData: Conference?
        var eventType: String?
    }

    struct Time: Decodable {
        var dateTime: String?
        var date: String? // all-day events have only a date
    }

    struct Person: Decodable {
        var email: String?
        var displayName: String?
        var isSelf: Bool?
        var organizer: Bool?
        var resource: Bool?
        var responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case email, displayName, organizer, resource, responseStatus
            case isSelf = "self"
        }
    }

    struct Conference: Decodable {
        var entryPoints: [EntryPoint]?
    }

    struct EntryPoint: Decodable {
        var entryPointType: String?
        var uri: String?
    }
}
