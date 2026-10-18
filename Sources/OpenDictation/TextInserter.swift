import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the frontmost app: save clipboard → set text →
/// synthesize ⌘V → restore clipboard. The paste route is the only one that works
/// uniformly across Mail, browsers, Electron apps, and terminals.
enum TextInserter {

    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        pasteKeystroke()

        // Restore the old clipboard after the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Only restore if nobody else touched the clipboard in the meantime.
            if pb.string(forType: .string) == text {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
        }
    }

    private static func pasteKeystroke() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
