import Foundation

/// `OpenDictation --check`: asserts the text-cleanup rules and the config parser, prints PASS/FAIL, exits 0/1.
/// Runs without a window, a microphone or any permission, so it works in CI and in a fresh install.
enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0
        func expect(_ name: String, _ got: String, _ want: String) {
            if got == want { print("PASS  \(name)") }
            else { failures += 1; print("FAIL  \(name)\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)") }
        }
        let en = LanguagePack.en, pl = LanguagePack.pl
        expect("en: fillers removed, sentence capitalised",
               LocalCleanup.clean("um so this is uh a test", pack: en), "So this is a test")
        expect("en: spoken commands",
               LocalCleanup.clean("hello comma world period new line second line", pack: en), "Hello, world.\nSecond line")
        expect("en: 'period of time' left alone",
               LocalCleanup.clean("it was a period of time", pack: en), "It was a period of time")
        expect("pl: Polish fillers and commands",
               LocalCleanup.clean("yyy cześć przecinek co słychać znak zapytania", pack: pl), "Cześć, co słychać?")
        expect("en pack does not touch Polish words",
               LocalCleanup.clean("to jest kropka", pack: en), "To jest kropka")
        expect("pl: hallucination list", pl.hallucinations.contains("dziękuję za uwagę") ? "yes" : "no", "yes")
        expect("en: hallucination list", en.hallucinations.contains("thanks for watching") ? "yes" : "no", "yes")
        // config parsing: bad values fall back to defaults
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("od-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? "{\"language\":\"PL\",\"pack\":\"xx\",\"hotkey\":\"right-option\",\"aiPolish\":\"maybe\"}".write(to: tmp, atomically: true, encoding: .utf8)
        let c = AppConfig.load(from: tmp)
        expect("config: language lowercased", c.language, "pl")
        expect("config: unknown pack -> en", c.pack, "en")
        expect("config: hotkey", c.hotkey, "right-option")
        expect("config: bad aiPolish -> auto", c.aiPolish, "auto")
        expect("config: missing file -> defaults", AppConfig.load(from: URL(fileURLWithPath: "/nonexistent.json")).hotkey, "fn")
        // the polish reply check: a reply is rejected, a cleanup is accepted
        expect("reply check: cleanup accepted", Pipeline.notACleanup("Can you open the PDF?", of: "um can you open the pdf") ?? "accepted", "accepted")
        expect("reply check: answer rejected", Pipeline.notACleanup("Sure! I would be happy to open that file for you right away.", of: "open the pdf") == nil ? "accepted" : "rejected", "rejected")
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
