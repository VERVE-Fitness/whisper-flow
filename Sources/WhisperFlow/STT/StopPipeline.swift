import Foundation

/// The decisions the stop pipeline makes that are pure enough to test on
/// their own, away from a live microphone and a loaded speech model.
enum StopPipeline {
    /// Which text a dictation should actually use, given the result of
    /// `finishStream()` and the last streaming partial the pill was showing.
    ///
    /// `finished` is nil when `finishStream()` timed out or threw. That used
    /// to lose the whole dictation (and, before the timeout existed, wedge
    /// the app on "Cleaning…" with no way out but force-quit). The words are
    /// not actually lost in that case: the sliding-window decoder has been
    /// publishing confirmed + volatile text to the pill the whole time, so
    /// the partial is a real, usually complete transcript -- at worst it is
    /// missing the last word or two the final pass would have committed.
    /// Using it is strictly better than throwing the dictation away.
    ///
    /// Returns nil only when there is nothing to insert at all, which the
    /// caller treats as a discard.
    static func rawText(finished: String?, partial: String) -> String? {
        if let finished, !finished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finished
        }
        return partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : partial
    }
}
