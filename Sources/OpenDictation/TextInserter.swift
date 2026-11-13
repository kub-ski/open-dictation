import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor of the frontmost app: save clipboard → set text →
/// synthesize ⌘V → restore clipboard. The paste route is the only one that works
/// uniformly across Mail, browsers, Electron apps, and terminals.
enum TextInserter {

    /// nspasteboard.org marker: clipboard managers skip content marked transient, so they do not keep a copy
    /// of every dictation (which would otherwise sit in their history, unencrypted, long after it was pasted).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        // Everything on the clipboard, not only its plain text: an image or rich text copied before
        // dictating used to come back as nothing.
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transient)
        let ours = pb.changeCount

        pasteKeystroke()

        // Restore the old clipboard after the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Only restore if nobody else touched the clipboard in the meantime.
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
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
