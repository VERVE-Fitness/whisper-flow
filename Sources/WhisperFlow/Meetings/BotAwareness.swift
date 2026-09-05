import Foundation

/// Whether VERVE Notes is already in the room. Niall can send a bot to a
/// meeting he is also sitting in, and two recordings of the same conversation
/// is two of everything: two summaries, two sets of draft actions, two
/// recordings to delete. So before the consent gate the app asks Flow what
/// its bots are doing and, if one has this meeting, offers to leave it alone.
///
/// The decision is pure on purpose: it is a function of the bot list and the
/// clock, so it is tested with fixed dates rather than by starting a
/// recording. Everything that draws an alert lives in ConsentGate.
enum BotAwareness {
    /// A bot scheduled to join within ten minutes counts as already having
    /// the meeting: it is close enough that recording here as well would end
    /// up with two copies of the same call.
    static let scheduledLeadSeconds: Double = 600

    /// The bot is in the room right now.
    static let liveStatuses: Set<String> = ["joining", "in_call"]
    /// The bot is booked but has not joined yet.
    static let scheduledStatus = "scheduled"

    /// What the alert says when the bot's row carries no title.
    static let untitledMeeting = "this meeting"

    enum Decision: Equatable {
        /// A bot has this meeting. The payload is what to call it in the alert.
        case botHasIt(title: String)
        /// Nothing of ours is recording; carry on to the consent gate.
        case clear
    }

    /// The one bot worth mentioning, or `.clear`. A bot already in the call
    /// beats one still joining, which beats one merely scheduled; among
    /// equals, the one starting soonest wins, so the alert names the meeting
    /// about to happen rather than one later in the morning.
    static func decide(bots: [FlowActiveBot], now: Date) -> Decision {
        let claiming = bots.filter { claims($0, now: now) }
        let ordered = claiming.sorted { a, b in
            let pa = priority(a), pb = priority(b)
            if pa != pb { return pa < pb }
            return startOrder(a, now: now) < startOrder(b, now: now)
        }
        guard let bot = ordered.first else { return .clear }
        return .botHasIt(title: title(of: bot))
    }

    /// Does this bot have the meeting the person is about to record?
    static func claims(_ bot: FlowActiveBot, now: Date) -> Bool {
        if liveStatuses.contains(bot.status) { return true }
        guard bot.status == scheduledStatus else { return false }
        // No start time on a bot the server already limited to the last four
        // hours means it is due about now, so it counts. A start time counts
        // when it is inside the next ten minutes, or has already passed and
        // the bot has not joined yet.
        guard let startsAt = bot.startsAt else { return true }
        return startsAt.timeIntervalSince(now) <= scheduledLeadSeconds
    }

    static func title(of bot: FlowActiveBot) -> String {
        let trimmed = (bot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledMeeting : trimmed
    }

    private static func priority(_ bot: FlowActiveBot) -> Int {
        switch bot.status {
        case "in_call": return 0
        case "joining": return 1
        default: return 2
        }
    }

    private static func startOrder(_ bot: FlowActiveBot, now: Date) -> Double {
        bot.startsAt?.timeIntervalSince(now) ?? 0
    }

    /// Every decision reaches stderr, including the quiet one: when a
    /// recording turns out to be a duplicate later, the log has to say
    /// whether the app looked and what it saw.
    static func logDecision(_ decision: Decision, bots: [FlowActiveBot]) {
        let line: String
        switch decision {
        case .botHasIt(let title):
            line = "[bot] VERVE Notes already has \(title); offering to leave it to the bot"
        case .clear:
            line = bots.isEmpty
                ? "[bot] no active bots, going on to the consent gate"
                : "[bot] \(bots.count) bot(s) active but none on this meeting, going on to the consent gate"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func logUnavailable(_ error: Error) {
        FileHandle.standardError.write(Data("[bot] could not ask Flow what its bots are doing (\(error.localizedDescription)); recording as normal\n".utf8))
    }
}
