import AppKit
import SwiftUI

/// Floating pill at the bottom-center of the screen while recording/processing —
/// non-activating so focus never leaves the app being dictated into.
@MainActor
final class HUD {
    private var panel: NSPanel?

    func show(_ text: String, recording: Bool) {
        let view = NSHostingView(rootView: HUDView(text: text, recording: recording))
        // Size to fit the content so nothing truncates ("Słucham…" was clipping at fixed width).
        let fitting = view.fittingSize
        let size = NSSize(width: max(140, fitting.width), height: max(44, fitting.height))
        view.frame = NSRect(origin: .zero, size: size)

        if panel == nil {
            let p = NSPanel(contentRect: view.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        guard let panel else { return }
        panel.setContentSize(size)
        panel.contentView = view
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 28))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct HUDView: View {
    let text: String
    let recording: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recording ? Color.red : Color.orange)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .fixedSize()
        .onAppear { pulse = true }
    }
}
