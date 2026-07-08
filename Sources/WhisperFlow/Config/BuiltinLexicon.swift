import Foundation

/// Vocabulary compiled into the app itself, merged UNDER the user's editable
/// lexicon.json (user entries always win on key collisions). This exists
/// because the Parakeet acoustic model has never seen VERVE's product names —
/// "the VERVE Tori" comes out as "devertory" or gets dropped — and every
/// machine running this build should recover from those mishearings out of
/// the box, without each user having to rediscover and hand-seed them.
///
/// VERVE Fitness's number one product is the VERVE Tori Functional Trainer;
/// its component words are the ones worth hard-coding.
enum BuiltinLexicon {
    /// Terms injected into the cleanup LLM's prompt as spelling targets, and
    /// credited by CleanupRouter's retention/additions guards.
    static let dictionary: [String] = [
        "VERVE",
        "Tori",
        "VERVE Tori",
        "Functional Trainer",
        "VERVE Tori Functional Trainer",
        "Pulse",
        "VERVE Pulse",
    ]

    /// Deterministic misheard -> corrected replacements (case-insensitive,
    /// whole-word/phrase), applied to the final text on every path — even
    /// when no LLM is available. Keys are the mishearings Parakeet actually
    /// produces for these terms, plus casing fixes for correctly-heard words.
    ///
    /// Keep entries conservative: every key must be either (a) a non-word
    /// that can't appear in legitimate dictation ("devertory"), or (b) a
    /// casing-only fix for a term that, in this company's dictation, always
    /// refers to the product/brand ("verve" -> "VERVE").
    static let corrections: [String: String] = [
        // Casing fixes for correctly-recognized words.
        "verve": "VERVE",
        "tori": "Tori",
        "functional trainer": "Functional Trainer",
        // Mishearings of "Tori".
        "tory": "Tori",
        "torey": "Tori",
        "torry": "Tori",
        // Observed Parakeet collapses of "the VERVE Tori" (see usage log
        // 2026-07-08: spoken "the VERVE Tori Functional Trainer" transcribed
        // as "devertory functional training").
        "devertory": "the VERVE Tori",
        "vertory": "VERVE Tori",
        "the verve tory": "the VERVE Tori",
    ]
}
