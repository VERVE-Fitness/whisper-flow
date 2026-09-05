import Foundation
import AppKit
import UserNotifications

/// Which of the caller's upcoming meetings deserve a "shall I record this?"
/// notification, and what that notification says. All of it pure, so the
/// timing rules are tested with fixed dates; everything that talks to macOS
/// is in MeetingPromptNotifier below.
enum CalendarPrompter {
    /// A meeting is prompted for while it is between one and two minutes
    /// away. Earlier and the person has not sat down yet; later and the
    /// meeting has started without a recording.
    static let leadMinSeconds: Double = 60
    static let leadMaxSeconds: Double = 120
    /// How often the calendar is read while connected and not recording.
    static let pollSeconds: Double = 60
    /// How many attendee first names the notification body carries.
    static let namesInBody = 3

    static let promptsEnabledDefaultsKey = "meetingPrompts"

    /// On by default. `UserDefaults.bool` answers false for a key nobody has
    /// set, so the absent case is read by hand rather than inherited.
    static func promptsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: promptsEnabledDefaultsKey) as? Bool ?? true
    }

    static func setPromptsEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: promptsEnabledDefaultsKey)
    }

    /// A bot Flow already has on the way owns the meeting. A failed one owns
    /// nothing, so that event is the app's to offer. An event with no join
    /// link never has a bot at all, which is why an in-person meeting always
    /// qualifies.
    static func hasLiveBot(_ event: FlowCalendarEvent) -> Bool {
        guard let bot = event.bot else { return false }
        return bot.status != "failed"
    }

    /// The events to put a notification up for right now.
    static func eventsToPrompt(events: [FlowCalendarEvent],
                               now: Date,
                               alreadyPrompted: Set<String>,
                               promptsEnabled: Bool) -> [FlowCalendarEvent] {
        guard promptsEnabled else { return [] }
        return events
            .filter { skipReason($0, now: now, alreadyPrompted: alreadyPrompted) == nil }
            .sorted { $0.start < $1.start }
    }

    /// Why this event is not being prompted for, in words, or nil when it
    /// should be. One function so the log and the decision cannot drift.
    static func skipReason(_ event: FlowCalendarEvent,
                           now: Date,
                           alreadyPrompted: Set<String>) -> String? {
        if alreadyPrompted.contains(event.id) { return "already asked about it today" }
        let lead = event.start.timeIntervalSince(now)
        if lead < leadMinSeconds { return "starts in \(Int(lead.rounded()))s, inside the window" }
        if lead > leadMaxSeconds { return "starts in \(Int((lead / 60).rounded()))min, not near enough yet" }
        if event.attendees.isEmpty { return "nobody else is on it" }
        if hasLiveBot(event) { return "VERVE Notes is already going (\(event.bot?.status ?? "bot"))" }
        return nil
    }

    // MARK: - Copy

    static func subject(of event: FlowCalendarEvent) -> String {
        let trimmed = event.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this meeting" : trimmed
    }

    static func notificationTitle(for event: FlowCalendarEvent) -> String {
        "Record \(subject(of: event))?"
    }

    static func notificationBody(for event: FlowCalendarEvent) -> String {
        let names = firstNames(event.attendees, limit: namesInBody)
        guard !names.isEmpty else { return "Starts in a minute." }
        return "With \(sentenceList(names)). Starts in a minute."
    }

    /// "Nathan Hall" reads as Nathan. An address that slipped through the
    /// server's name lookup reads as its local part rather than a domain.
    static func firstNames(_ attendees: [String], limit: Int) -> [String] {
        var out: [String] = []
        for attendee in attendees {
            let trimmed = attendee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let head = trimmed.contains("@") ? String(trimmed.split(separator: "@")[0]) : trimmed
            let first = head.split(whereSeparator: { $0 == " " || $0 == "." }).first.map(String.init) ?? head
            guard !first.isEmpty else { continue }
            out.append(first.prefix(1).uppercased() + first.dropFirst())
            if out.count == limit { break }
        }
        return out
    }

    /// "Nathan", "Nathan and Giuseppe", "Nathan, Giuseppe and Ella".
    static func sentenceList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    // MARK: - Log

    /// One line per poll, plus a line for every event near enough to have
    /// been a candidate. Events hours away are not logged: a quiet log is one
    /// somebody reads.
    static func logPoll(events: [FlowCalendarEvent], due: [FlowCalendarEvent],
                        now: Date, alreadyPrompted: Set<String>) {
        var lines = ["[prompt] \(events.count) event(s) in the next two hours, \(due.count) to ask about"]
        for event in events {
            let lead = event.start.timeIntervalSince(now)
            guard lead <= leadMaxSeconds, lead >= -leadMaxSeconds else { continue }
            if let reason = skipReason(event, now: now, alreadyPrompted: alreadyPrompted) {
                lines.append("[prompt] skipping \(subject(of: event)): \(reason)")
            } else {
                lines.append("[prompt] asking about \(subject(of: event)) (starts in \(Int(lead.rounded()))s)")
            }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    static func logPollFailed(_ error: Error) {
        FileHandle.standardError.write(Data("[prompt] could not read the calendar (\(error.localizedDescription)); trying again in \(Int(pollSeconds))s\n".utf8))
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data("[prompt] \(line)\n".utf8))
    }
}

/// Which day's prompts have already been shown. Ids are kept for the day so a
/// meeting that sits in the window for a full minute is asked about once, and
/// yesterday's ids do not accumulate forever.
enum PromptedEventStore {
    static let defaultsKey = "promptedEventIds"

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Adds one id under today's key and drops every other day, so the stored
    /// value is only ever one day wide.
    static func merged(_ existing: [String: [String]], id: String, dayKey: String) -> [String: [String]] {
        var today = existing[dayKey] ?? []
        if !today.contains(id) { today.append(id) }
        return [dayKey: today]
    }

    static func prompted(on date: Date, defaults: UserDefaults = .standard) -> Set<String> {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        return Set(stored[dayKey(date)] ?? [])
    }

    static func remember(_ id: String, on date: Date = Date(), defaults: UserDefaults = .standard) {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        defaults.set(merged(stored, id: id, dayKey: dayKey(date)), forKey: defaultsKey)
    }
}

/// The macOS half: one notification category, two actions, and an NSAlert for
/// the Mac where notifications were refused. Deliberately thin -- it decides
/// nothing, it only asks.
@MainActor
final class MeetingPromptNotifier {
    static let categoryIdentifier = "meeting-prompt"
    static let recordAction = "record"
    static let skipAction = "skip"
    static let recordButton = "Record"
    static let skipButton = "Not this one"

    /// userInfo keys, read back by the app delegate when the person answers.
    static let eventIdKey = "eventId"
    static let subjectKey = "subject"
    static let attendeesKey = "attendees"

    enum Outcome: Equatable {
        /// A notification is up; the answer arrives at the app delegate.
        case delivered
        /// The alert fallback was answered there and then.
        case record
        case skip
        /// Nothing was shown (an alert is already up, or this process has no
        /// bundle to post a notification from).
        case notShown
    }

    private var didRequestAuthorisation = false
    private var authorised = false
    private var alertIsUp = false

    /// A bare executable (the CLI harnesses, the test binary) has no bundle
    /// identifier, and UNUserNotificationCenter.current() traps in that case.
    /// Those runs fall back to the alert.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Called once, on the first connect. The delegate is set by the app
    /// delegate before this runs: an LSUIElement app with no delegate
    /// delivers the person's answer nowhere.
    func requestAuthorisationOnce() async {
        guard !didRequestAuthorisation else { return }
        didRequestAuthorisation = true
        guard notificationsAvailable else {
            CalendarPrompter.log("no app bundle, so meeting prompts will use an alert")
            return
        }
        let centre = UNUserNotificationCenter.current()
        centre.setNotificationCategories([Self.category()])
        do {
            authorised = try await centre.requestAuthorization(options: [.alert, .sound])
            CalendarPrompter.log(authorised
                ? "notifications allowed, meeting prompts will appear as notifications"
                : "notifications refused, meeting prompts will appear as an alert")
        } catch {
            authorised = false
            CalendarPrompter.log("could not ask about notifications (\(error.localizedDescription)); meeting prompts will use an alert")
        }
    }

    static func category() -> UNNotificationCategory {
        let record = UNNotificationAction(identifier: recordAction, title: recordButton, options: [.foreground])
        let skip = UNNotificationAction(identifier: skipAction, title: skipButton, options: [])
        return UNNotificationCategory(identifier: categoryIdentifier,
                                      actions: [record, skip],
                                      intentIdentifiers: [],
                                      options: [])
    }

    /// Asks about one meeting. Returns how it was asked, so the caller knows
    /// whether to wait for the delegate or act now.
    func prompt(event: FlowCalendarEvent) async -> Outcome {
        let title = CalendarPrompter.notificationTitle(for: event)
        let body = CalendarPrompter.notificationBody(for: event)
        guard notificationsAvailable, authorised else {
            return presentAlert(title: title, body: body)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.eventIdKey: event.id,
                            Self.subjectKey: CalendarPrompter.subject(of: event),
                            Self.attendeesKey: event.attendees]
        let request = UNNotificationRequest(identifier: "meeting-prompt-" + event.id,
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .delivered
        } catch {
            CalendarPrompter.log("could not post the notification (\(error.localizedDescription)); asking with an alert")
            return presentAlert(title: title, body: body)
        }
    }

    /// The fallback. One at a time: a Mac waking to three meetings must not
    /// stack three modal alerts on top of each other, so anything that
    /// arrives while one is up is left for the next poll.
    private func presentAlert(title: String, body: String) -> Outcome {
        guard !alertIsUp else {
            CalendarPrompter.log("an alert is already up, leaving this one for the next poll")
            return .notShown
        }
        alertIsUp = true
        defer { alertIsUp = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: Self.recordButton)
        alert.addButton(withTitle: Self.skipButton)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .record : .skip
    }
}
