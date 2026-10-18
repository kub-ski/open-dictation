import AppKit
import IOKit.hid

/// Watches the push-to-talk modifier key (Fn, keyCode 63, unless configured otherwise) via a listen-only CGEventTap and classifies:
///   hold ≥ holdThreshold → push-to-talk (onStart on press, onStop on release)
///   tap-tap within doubleTapWindow → locked recording (onStart on first press, onLock on second)
///   while locked, any Fn press → onStop
///   single short tap that stays single → onCancel (accidental)
///   any OTHER key pressed while Fn is held before classification → onCancel (Fn was a modifier)
/// CGEventTap (not NSEvent monitors) because taps also receive synthesized events and are the
/// reliable path on current macOS. Requires the Input Monitoring TCC grant; tap creation fails
/// without it, so we request access and retry until granted.
final class HotkeyMonitor {

    /// The push-to-talk key (Fn by default; see AppConfig.hotkey).
    var hotkey: Hotkey = Hotkey.all[AppConfig.current.hotkey] ?? Hotkey.all["fn"]!

    var onStart: (() -> Void)?
    var onLock: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let holdThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.40

    private var tap: CFMachPort?
    private var fnIsDown = false
    private var fnDownAt: Date?
    private var awaitingSecondTap = false
    private var locked = false
    private var recordingActive = false
    private var singleTapTimer: Timer?
    private var retryTimer: Timer?

    func start() {
        let listenStatus = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.write("monitor: input-monitoring access = \(listenStatus.rawValue) (0=granted)")
        createTap()
        if tap == nil {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Log.write("monitor: tap failed — requested Input Monitoring, retrying every 3 s")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.tap == nil else { self?.retryTimer?.invalidate(); return }
                self.createTap()
                if self.tap != nil { Log.write("monitor: tap active after retry") }
            }
        }
    }

    private func createTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                place: .headInsertEventTap,
                                options: .listenOnly,
                                eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("monitor: CGEventTap active")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall — re-enable immediately.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.write("monitor: tap re-enabled after disable (\(type.rawValue))")
            return
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            guard keycode == hotkey.keyCode else { return }
            let down = event.flags.contains(hotkey.flag)
            DispatchQueue.main.async { self.handleFn(down: down) }
        } else if type == .keyDown {
            DispatchQueue.main.async { self.handleOtherKey() }
        }
    }

    private func handleFn(down: Bool) {
        Log.write("monitor: fn \(down ? "down" : "up") (fnIsDown=\(fnIsDown) locked=\(locked) awaiting2nd=\(awaitingSecondTap))")
        if down {
            guard !fnIsDown else { return }
            fnIsDown = true

            if locked {
                // Locked recording → this press stops it.
                locked = false
                recordingActive = false
                onStop?()
                return
            }
            if awaitingSecondTap {
                // Second tap inside the window → lock the recording that's already running.
                awaitingSecondTap = false
                singleTapTimer?.invalidate()
                locked = true
                onLock?()
                return
            }
            // Fresh press → start recording immediately (hold-to-talk feel).
            fnDownAt = Date()
            recordingActive = true
            onStart?()
        } else {
            guard fnIsDown else { return }
            fnIsDown = false
            guard recordingActive, !locked else { return }
            guard let downAt = fnDownAt else { return }

            let heldFor = Date().timeIntervalSince(downAt)
            if heldFor >= holdThreshold {
                // Push-to-talk release → done.
                recordingActive = false
                onStop?()
            } else {
                // Short tap: either the first half of a double-tap, or an accident.
                awaitingSecondTap = true
                singleTapTimer?.invalidate()
                singleTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self, self.awaitingSecondTap else { return }
                    self.awaitingSecondTap = false
                    self.recordingActive = false
                    self.onCancel?()
                }
            }
        }
    }

    /// Fn is being used as a modifier (Fn+arrows etc.) — abort the accidental recording.
    private func handleOtherKey() {
        guard fnIsDown, recordingActive, !locked else { return }
        recordingActive = false
        awaitingSecondTap = false
        singleTapTimer?.invalidate()
        onCancel?()
    }
}
