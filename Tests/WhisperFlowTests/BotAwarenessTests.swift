import XCTest
@testable import WhisperFlow

/// Fixed clock throughout: the ten minute rule is the whole point, so every
/// case names its own "now" rather than leaning on Date().
final class BotAwarenessTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-05T09:00:00Z")!

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func bot(_ id: String, status: String, title: String? = "Nathan 1:1",
                     startsAt: Date? = nil) -> FlowActiveBot {
        FlowActiveBot(id: id, title: title, meetingURL: "https://teams.microsoft.com/l/meetup-join/x",
                      startsAt: startsAt, status: status, calendarEventId: "AAMkAD")
    }

    func testNoBotsIsClear() {
        XCTAssertEqual(BotAwareness.decide(bots: [], now: now), .clear)
    }

    func testABotInTheCallOwnsTheMeeting() {
        let decision = BotAwareness.decide(bots: [bot("b1", status: "in_call")], now: now)
        XCTAssertEqual(decision, .botHasIt(title: "Nathan 1:1"))
    }

    func testABotStillJoiningOwnsTheMeeting() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "joining")], now: now),
                       .botHasIt(title: "Nathan 1:1"))
    }

    func testAScheduledBotInsideTenMinutesOwnsTheMeeting() {
        let decision = BotAwareness.decide(bots: [bot("b1", status: "scheduled", startsAt: at(9))], now: now)
        XCTAssertEqual(decision, .botHasIt(title: "Nathan 1:1"))
    }

    func testExactlyTenMinutesAwayStillCounts() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "scheduled", startsAt: at(10))], now: now),
                       .botHasIt(title: "Nathan 1:1"))
    }

    /// Eleven minutes out is a different meeting: recording now is not a
    /// duplicate of something that has not started.
    func testAScheduledBotBeyondTenMinutesIsClear() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "scheduled", startsAt: at(11))], now: now),
                       .clear)
    }

    /// A bot booked for a time that has already passed and has not joined yet
    /// is about to join, not finished.
    func testAScheduledBotWhoseStartHasPassedStillCounts() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "scheduled", startsAt: at(-3))], now: now),
                       .botHasIt(title: "Nathan 1:1"))
    }

    func testAScheduledBotWithNoStartTimeCounts() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "scheduled", startsAt: nil)], now: now),
                       .botHasIt(title: "Nathan 1:1"))
    }

    /// The endpoint should not send these, but a bot that has finished or
    /// fallen over must never stop a person recording.
    func testFinishedAndFailedBotsAreClear() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "done", startsAt: at(-30)),
                                                  bot("b2", status: "failed", startsAt: at(1)),
                                                  bot("b3", status: "ingesting", startsAt: at(-5))],
                                           now: now), .clear)
    }

    /// The alert names one meeting, so the bot actually in the room wins over
    /// one that is only booked.
    func testTheBotInTheCallIsNamedAheadOfAScheduledOne() {
        let bots = [bot("b1", status: "scheduled", title: "Leadership", startsAt: at(8)),
                    bot("b2", status: "in_call", title: "Nathan 1:1", startsAt: at(-10))]
        XCTAssertEqual(BotAwareness.decide(bots: bots, now: now), .botHasIt(title: "Nathan 1:1"))
    }

    func testAmongScheduledBotsTheSoonestIsNamed() {
        let bots = [bot("b1", status: "scheduled", title: "Later", startsAt: at(9)),
                    bot("b2", status: "scheduled", title: "Sooner", startsAt: at(2))]
        XCTAssertEqual(BotAwareness.decide(bots: bots, now: now), .botHasIt(title: "Sooner"))
    }

    func testABotWithNoTitleGetsReadableWording() {
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "in_call", title: nil)], now: now),
                       .botHasIt(title: "this meeting"))
        XCTAssertEqual(BotAwareness.decide(bots: [bot("b1", status: "in_call", title: "   ")], now: now),
                       .botHasIt(title: "this meeting"))
    }

    func testTheTenMinuteRuleIsOneConstant() {
        XCTAssertEqual(BotAwareness.scheduledLeadSeconds, 600)
    }
}
