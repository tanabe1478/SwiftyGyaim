import Foundation

/// Minimal copy of Zenz prompt control tags used by Zenz v3 models.
///
/// AzooKeyKanaKanjiConverter's `ZenzPromptBuilder` uses private-use Unicode
/// tags to separate context, input, and output. Keeping the tags centralized
/// lets SwiftyGyaim move toward the same prompt format without depending on the
/// full converter package.
enum ZenzPrompt {
    static let inputTag = "\u{EE00}"
    static let outputTag = "\u{EE01}"
    static let contextTag = "\u{EE02}"
}
