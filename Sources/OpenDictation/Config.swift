import Foundation
import CoreGraphics

/// Everything the user can set, in one place.
///
/// The app's name comes from its own Info.plist (setup.sh writes it), so one source tree can become
/// any number of differently named apps. Settings live in `~/.<slug>/config.json`:
///
///     { "language": "auto", "pack": "en", "hotkey": "fn", "aiPolish": "auto", "model": "ggml-small.bin" }
///
/// A missing or broken file means the defaults below. Nothing here ever throws.
struct AppConfig {
    /// Whisper language code ("auto", "en", "pl", "de", …).
    var language = "auto"
    /// Cleanup language pack: "en" or "pl". Fillers and spoken commands ("new line") come from it.
    var pack = "en"
    /// "fn", "right-option", "right-command", "right-control" or "left-control".
    var hotkey = "fn"
    /// "auto" = use the `claude` CLI when it is installed and signed in, "on" = always try, "off" = never.
    var aiPolish = "auto"
    /// Test URLs (<app>://selftest, dictate-file, …). Off, so a web page cannot trigger them.
    var testHooks = false
    /// Whisper model file in ~/.<slug>/models/.
    var model = "ggml-small.bin"

    static let displayName: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "OpenDictation"

    /// "Test Dictate" → "testdictate". Used for the support folder and the URL scheme.
    static let slug: String = {
        let s = displayName.lowercased().filter { $0.isLetter || $0.isNumber }
        return s.isEmpty ? "opendictation" : s
    }()

    /// History, logs and leftover audio live here. Home folders on macOS are readable by every account on the Mac,
    /// so this folder is made private to the user (0700), also when an older version created it open.
    static let supportDir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(slug)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }()

    static let fileURL = supportDir.appendingPathComponent("config.json")

    static func load(from url: URL = fileURL) -> AppConfig {
        var c = AppConfig()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = obj["language"] as? String, !v.isEmpty { c.language = v.lowercased() }
        if let v = obj["pack"] as? String, LanguagePack.all[v.lowercased()] != nil { c.pack = v.lowercased() }
        if let v = obj["hotkey"] as? String, Hotkey.all[v.lowercased()] != nil { c.hotkey = v.lowercased() }
        if let v = obj["aiPolish"] as? String, ["auto", "on", "off"].contains(v.lowercased()) { c.aiPolish = v.lowercased() }
        if let v = obj["testHooks"] as? Bool { c.testHooks = v }
        if let v = obj["model"] as? String, !v.isEmpty, !v.contains("/") { c.model = v }
        return c
    }

    static let current = load()
}

/// A modifier key that can be the push-to-talk key.
struct Hotkey {
    let keyCode: Int64
    let flag: CGEventFlags
    let label: String

    static let all: [String: Hotkey] = [
        "fn":            Hotkey(keyCode: 63, flag: .maskSecondaryFn, label: "Fn"),
        "right-option":  Hotkey(keyCode: 61, flag: .maskAlternate,   label: "Right Option"),
        "right-command": Hotkey(keyCode: 54, flag: .maskCommand,     label: "Right Command"),
        "right-control": Hotkey(keyCode: 62, flag: .maskControl,     label: "Right Control"),
        "left-control":  Hotkey(keyCode: 59, flag: .maskControl,     label: "Left Control"),
    ]
}
