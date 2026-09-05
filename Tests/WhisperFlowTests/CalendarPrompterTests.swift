import XCTest
@testable import WhisperFlow

/// The prompt window is sixty to a hundred and twenty seconds, so every case
/// here names its own "now" and builds events around it. Nothing touches the
/// clock, the network or Notification Centre.
final class CalendarPrompterTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-05T09:00:00Z")!

    private func event(_ id: String,
                       subject: String = "Nathan 1:1",
                       inSeconds: Double,
                       attendees: [String] = ["Nathan Hall"],
                       joinURL: String? = "https://teams.microsoft.com/l/meetup-join/x",
                       bot: FlowEventBot? = nil) -> FlowCalendarEvent {
        FlowCalendarEvent(id: id, subject: subject, start: now.addingTimeInterval(inSeconds),
                          end: now.addingTimeInterval(inSeconds + 1800),
                          isOnline: joinURL != nil, joinURL: joinURL,
                          attendees: attendees, organizer: "Niall Wogan", response: "organizer", bot: bot)
    }

    private func due(_ events: [FlowCalendarEvent],
                     prompted: Set<String> = [],
                     enabled: Bool = true) -> [FlowCalendarEvent] {
        CalendarPrompter.eventsToPrompt(events: events, now: now,
                                        alreadyPrompted: prompted, promptsEnabled: enabled)
    }

    // MARK: - The window

    func testAMeetingNinetySecondsAwayIsPromptedFor() {
        XCTAssertEqual(due([event("e1", inSeconds: 90)]).map(\.id), ["e1"])
    }

    func testTheEdgesOfTheWindowAreIncluded() {
        XCTAssertEqual(due([event("e1", inSeconds: 60)]).map(\.id), ["e1"])
        XCTAssertEqual(due([event("e2", inSeconds: 120)]).map(\.id), ["e2"])
    }

    func testTooSoonAndTooFarAreBothLeftAlone() {
        XCTAssertTrue(due([event("e1", inSeconds: 59)]).isEmpty)
        XCTAssertTrue(due([event("e2", inSeconds: 121)]).isEmpty)
        XCTAssertTrue(due([event("e3", inSeconds: 3600)]).isEmpty)
    }

    /// A meeting that has already started is not offered: the prompt is for
    /// sitting down to it, not for joining it late.
    func testAMeetingAlreadyUnderWayIsNotPromptedFor() {
        XCTAssertTrue(due([event("e1", inSeconds: -300)]).isEmpty)
    }

    // MARK: - Who and what

    func testAMeetingWithNobodyElseOnItIsNotPromptedFor() {
        XCTAssertTrue(due([event("e1", inSeconds: 90, attendees: [])]).isEmpty)
    }

    /// An in-person meeting has no join link and so never has a bot; it is
    /// exactly the case the prompt exists for.
    func testAnInPersonMeetingQualifies() {
        XCTAssertEqual(due([event("e1", subject: "Showroom walkthrough", inSeconds: 90,
                                  attendees: ["Ella Xie"], joinURL: nil)]).map(\.id), ["e1"])
    }

    func testAMeetingWithABotOnTheWayIsLeftToTheBot() {
        for status in ["scheduled", "joining", "in_call", "ingesting", "done"] {
            let e = event("e1", inSeconds: 90, bot: FlowEventBot(id: "bot-1", status: status))
            XCTAssertTrue(due([e]).isEmpty, "a bot with status \(status) should own the meeting")
        }
    }

    /// A bot that fell over recorded nothing, so the meeting is the app's to
    /// offer after all.
    func testAFailedBotDoesNotStopThePrompt() {
        let e = event("e1", inSeconds: 90, bot: FlowEventBot(id: "bot-1", status: "failed"))
        XCTAssertEqual(due([e]).map(\.id), ["e1"])
    }

    // MARK: - Once per event, and the toggle

    func testAnEventAlreadyAskedAboutIsNotAskedAgain() {
        XCTAssertTrue(due([event("e1", inSeconds: 90)], prompted: ["e1"]).isEmpty)
    }

    func testTheToggleSilencesEverything() {
        XCTAssertTrue(due([event("e1", inSeconds: 90)], enabled: false).isEmpty)
    }

    func testTwoMeetingsAtOnceComeBackSoonestFirst() {
        let later = event("later", subject: "Leadership", inSeconds: 110)
        let sooner = event("sooner", subject: "Nathan 1:1", inSeconds: 70)
        XCTAssertEqual(due([later, sooner]).map(\.id), ["sooner", "later"])
    }

    func testSkipReasonIsNilExactlyWhenThePromptFires() {
        XCTAssertNil(CalendarPrompter.skipReason(event("e1", inSeconds: 90), now: now, alreadyPrompted: []))
        XCTAssertNotNil(CalendarPrompter.skipReason(event("e1", inSeconds: 90), now: now, alreadyPrompted: ["e1"]))
        XCTAssertNotNil(CalendarPrompter.skipReason(event("e1", inSeconds: 90, attendees: []),
                                                    now: now, alreadyPrompted: []))
    }

    // MARK: - Copy

    func testTheNotificationReadsAsThePlanWroteIt() {
        let e = event("e1", subject: "Nathan 1:1", inSeconds: 90, attendees: ["Nathan Hall"])
        XCTAssertEqual(CalendarPrompter.notificationTitle(for: e), "Record Nathan 1:1?")
        XCTAssertEqual(CalendarPrompter.notificationBody(for: e), "With Nathan. Starts in a minute.")
    }

    func testUpToThreeFirstNames() {
        let e = event("e1", inSeconds: 90,
                      attendees: ["Nathan Hall", "Giuseppe Tappi", "Ella Xie", "Jacqueline Wogan"])
        XCTAssertEqual(CalendarPrompter.notificationBody(for: e),
                       "With Nathan, Giuseppe and Ella. Starts in a minute.")
    }

    func testTwoNamesReadWithAnAnd() {
        let e = event("e1", inSeconds: 90, attendees: ["Nathan Hall", "Giuseppe Tappi"])
        XCTAssertEqual(CalendarPrompter.notificationBody(for: e),
                       "With Nathan and Giuseppe. Starts in a minute.")
    }

    /// An address that got past the server's name lookup should still read
    /// like a person, not like a mailbox.
    func testAnAddressStillReadsAsAFirstName() {
        XCTAssertEqual(CalendarPrompter.firstNames(["nathan.hall@vervefitness.com.au"], limit: 3), ["Nathan"])
    }

    func testAnUntitledMeetingStillReads() {
        let e = event("e1", subject: "   ", inSeconds: 90)
        XCTAssertEqual(CalendarPrompter.notificationTitle(for: e), "Record this meeting?")
    }

    /// No em or en dashes anywhere in what the person sees.
    func testCopyCarriesNoDashes() {
        let e = event("e1", inSeconds: 90, attendees: ["Nathan Hall", "Giuseppe Tappi"])
        for line in [CalendarPrompter.notificationTitle(for: e), CalendarPrompter.notificationBody(for: e),
                     MeetingPromptNotifier.recordButton, MeetingPromptNotifier.skipButton] {
            XCTAssertFalse(line.contains("\u{2014}"), line)
            XCTAssertFalse(line.contains("\u{2013}"), line)
        }
    }

    func testTheTwoNotificationActionsAreNamedAsTheContractSays() {
        XCTAssertEqual(MeetingPromptNotifier.categoryIdentifier, "meeting-prompt")
        XCTAssertEqual(MeetingPromptNotifier.recordAction, "record")
        XCTAssertEqual(MeetingPromptNotifier.skipAction, "skip")
        XCTAssertEqual(MeetingPromptNotifier.recordButton, "Record")
        XCTAssertEqual(MeetingPromptNotifier.skipButton, "Not this one")
    }
}

/// Prompted ids last the day and no longer.
final class PromptedEventStoreTests: XCTestCase {
    private let today = "2026-09-05"
    private let yesterday = "2026-09-04"

    func testAnIdIsRememberedUnderToday() {
        let merged = PromptedEventStore.merged([:], id: "e1", dayKey: today)
        XCTAssertEqual(merged, [today: ["e1"]])
    }

    func testASecondIdJoinsTheSameDay() {
        var merged = PromptedEventStore.merged([:], id: "e1", dayKey: today)
        merged = PromptedEventStore.merged(merged, id: "e2", dayKey: today)
        XCTAssertEqual(merged[today], ["e1", "e2"])
    }

    func testTheSameIdIsNotStoredTwice() {
        var merged = PromptedEventStore.merged([:], id: "e1", dayKey: today)
        merged = PromptedEventStore.merged(merged, id: "e1", dayKey: today)
        XCTAssertEqual(merged[today], ["e1"])
    }

    /// Yesterday's meetings are gone, so the store never grows.
    func testYesterdayIsDropped() {
        let merged = PromptedEventStore.merged([yesterday: ["old1", "old2"]], id: "e1", dayKey: today)
        XCTAssertNil(merged[yesterday])
        XCTAssertEqual(merged[today], ["e1"])
    }

    func testDayKeyIsTheLocalDate() {
        let date = ISO8601DateFormatter().date(from: "2026-09-05T13:30:00Z")!
        XCTAssertEqual(PromptedEventStore.dayKey(date, timeZone: TimeZone(identifier: "UTC")!), "2026-09-05")
        // Gold Coast is UTC+10, so 13:30 UTC is the next morning there.
        XCTAssertEqual(PromptedEventStore.dayKey(date, timeZone: TimeZone(identifier: "Australia/Brisbane")!),
                       "2026-09-05")
        let late = ISO8601DateFormatter().date(from: "2026-09-05T20:30:00Z")!
        XCTAssertEqual(PromptedEventStore.dayKey(late, timeZone: TimeZone(identifier: "Australia/Brisbane")!),
                       "2026-09-06")
    }

    func testRoundTripThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "whisperflow.tests.prompted")!
        defaults.removePersistentDomain(forName: "whisperflow.tests.prompted")
        let now = Date()
        XCTAssertTrue(PromptedEventStore.prompted(on: now, defaults: defaults).isEmpty)
        PromptedEventStore.remember("e1", on: now, defaults: defaults)
        XCTAssertEqual(PromptedEventStore.prompted(on: now, defaults: defaults), ["e1"])
        defaults.removePersistentDomain(forName: "whisperflow.tests.prompted")
    }
}

/// The menu toggle: on unless somebody turned it off.
final class MeetingPromptsToggleTests: XCTestCase {
    private let suite = "whisperflow.tests.prompts"

    func testPromptsAreOnByDefaultAndRememberBeingTurnedOff() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(CalendarPrompter.promptsEnabled(defaults))
        CalendarPrompter.setPromptsEnabled(false, defaults)
        XCTAssertFalse(CalendarPrompter.promptsEnabled(defaults))
        CalendarPrompter.setPromptsEnabled(true, defaults)
        XCTAssertTrue(CalendarPrompter.promptsEnabled(defaults))
        defaults.removePersistentDomain(forName: suite)
    }
}
