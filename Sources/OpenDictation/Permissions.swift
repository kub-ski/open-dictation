import AppKit
import ApplicationServices

enum Permissions {
    /// Accessibility trust covers both the global Fn monitor and the synthesized ⌘V.
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
