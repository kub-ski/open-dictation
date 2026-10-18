import Foundation

/// Language-specific text cleanup: filler words, spoken formatting commands ("new line"), and the
/// phrases Whisper invents on silence. Whisper itself handles the language; a pack only tunes cleanup.
/// To add a language, add one entry to `all` (and, if you use AI polish, a prompts/pack-<id>.md note).
struct LanguagePack {
    let id: String
    let fillers: [String]
    /// regex alternatives → literal text
    let commands: [(pattern: String, replacement: String)]
    /// If the WHOLE transcript is one of these (lowercased), nothing was said.
    let hallucinations: Set<String>

    static let en = LanguagePack(
        id: "en",
        fillers: ["um", "uh", "erm", "uhh", "umm", "hmm", "mmm", "er", "mhm", "uh-huh"],
        commands: [
            ("new paragraph", "\n\n"),
            ("new line|next line", "\n"),
            ("question mark", "?"),
            ("exclamation mark|exclamation point", "!"),
            ("full stop|period", "."),
            ("comma", ","),
            ("colon", ":"),
            ("open paren|open parenthesis", "("),
            ("close paren|close parenthesis", ")"),
        ],
        hallucinations: ["thank you", "thank you.", "thanks for watching", "thanks for watching!",
                         "you", "bye", "bye.", "silence", "the end"]
    )

    static let pl = LanguagePack(
        id: "pl",
        fillers: en.fillers + ["yyy", "eee", "yy", "ee"],
        commands: en.commands + [
            ("nowy akapit", "\n\n"),
            ("nowa linia", "\n"),
            ("znak zapytania", "?"),
            ("wykrzyknik", "!"),
            ("kropka", "."),
            ("przecinek", ","),
            ("dwukropek", ":"),
        ],
        hallucinations: en.hallucinations.union([
            "dziękuję", "dziękuję.", "dziękuję za uwagę", "dziękuję za uwagę.", "dziękuje",
            "napisy stworzone przez społeczność amara.org", "zapraszam na kolejny film", "do zobaczenia"])
    )

    static let all: [String: LanguagePack] = ["en": en, "pl": pl]
    static func named(_ id: String) -> LanguagePack { all[id] ?? en }
}
