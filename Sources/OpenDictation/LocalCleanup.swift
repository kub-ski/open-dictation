import Foundation

/// Instant, zero-cost transcript cleanup (no LLM). Whisper large-v3-turbo already
/// punctuates and capitalizes well, so this only has to: strip fillers, apply spoken
/// formatting commands, normalize whitespace, and capitalize sentence starts.
/// This is the default path; the AI polish (your own `claude` CLI) is an optional upgrade.
enum LocalCleanup {

    static func clean(_ input: String, pack: LanguagePack = LanguagePack.named(AppConfig.current.pack)) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        // 1) Remove filler words (word-boundary, keep surrounding punctuation sane).
        for f in pack.fillers {
            s = replace(s, pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: f))\\b[,]?", with: " ")
        }

        // 2) Apply spoken formatting commands. Only fires when the word stands alone
        //    (surrounded by spaces/punctuation), so "period of time" is left untouched
        //    but "add a comma here period" resolves the trailing command.
        for (pattern, rep) in pack.commands {
            // "period" is also an ordinary noun ("a period of time"), so a spoken full stop only counts at the
            // end of the text or right before a line break; the other commands fire anywhere they stand alone.
            // Whisper often adds its own punctuation after the spoken word ("period." / "comma,"); swallow one mark.
            let after = rep == "." ? "[.,!?]?(?=\\s*$|\\s*\\n)" : "[.,!?;:]?(?=[\\s.,!?]|$)"
            s = replace(s, pattern: "(?i)(?<=\\s)(\(pattern))\(after)", with: NSRegularExpression.escapedTemplate(for: rep))
        }

        // 3) Whitespace: collapse runs of spaces, fix space-before-punctuation, drop
        //    space after an opening paren, keep intentional paragraph breaks.
        s = replace(s, pattern: "[ \\t]+", with: " ")
        s = replace(s, pattern: "\\s+([,.!?:;])", with: "$1")
        s = replace(s, pattern: "\\(\\s+", with: "(")
        s = replace(s, pattern: " *\\n *", with: "\n")
        s = replace(s, pattern: "\\n{3,}", with: "\n\n")

        // 4) Capitalize the first letter of the string and after sentence enders.
        s = capitalizeSentences(s)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeSentences(_ input: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in input {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
