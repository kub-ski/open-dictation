import AppKit
import AVFoundation
import Combine

/// Central state machine: idle → recording (held or locked) → processing → idle.
/// Owns the Fn monitor, the recorder, the pipeline, the HUD, and the history store.
@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        case processing
        case error(String)
    }

    @Published var phase: Phase = .idle {
        didSet { syncHUD() }
    }
    // AI polish runs through the user's own `claude` CLI (a few seconds slower) and sends each dictation's text
    // to Anthropic, so it is opt-in. Default follows config: "auto" = offered in the menu, off until ticked;
    // "on" = on when claude is installed and signed in; "off" = never.
    @Published var cleanupEnabled = false
    @Published var claudeAvailable = false
    @Published var permissionsOK = false

    let history = HistoryStore()
    private let monitor = HotkeyMonitor()
    let recorder = AudioRecorder()
    private let hud = HUD()
    private var recordingStartedAt: Date?
    private var targetApp: String = "?"

    var menuIcon: String {
        switch phase {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusLine: String {
        switch phase {
        case .idle: return "\(AppConfig.displayName) — ready"
        case .recording(let locked): return locked ? "Recording (locked)" : "Recording…"
        case .processing: return "Transcribing…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    init() {
        Log.write("app: launched (\(AppConfig.displayName), language \(AppConfig.current.language), pack \(AppConfig.current.pack), hotkey \(AppConfig.current.hotkey))")
        // is the user's own claude CLI usable? checked off the main thread (it runs a short command)
        if AppConfig.current.aiPolish != "off" {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let ok = Pipeline.claudeReady
                DispatchQueue.main.async {
                    self?.claudeAvailable = ok
                    self?.cleanupEnabled = ok && AppConfig.current.aiPolish == "on"
                    Log.write("app: claude CLI ready = \(ok); AI polish \(self?.cleanupEnabled == true ? "on" : "off")")
                }
            }
        }
        permissionsOK = Permissions.accessibilityTrusted(prompt: false)
        Log.write("app: accessibility trusted = \(permissionsOK), mic = \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        monitor.onStart = { [weak self] in self?.startRecording() }
        monitor.onLock = { [weak self] in self?.lockRecording() }
        monitor.onStop = { [weak self] in self?.stopAndProcess() }
        monitor.onCancel = { [weak self] in self?.cancelRecording() }
        monitor.start()
        // a mic delivered no sound: say so while the user is still talking, and keep recording on the next one
        recorder.onSwitch = { [weak self] from, to in
            guard let self else { return }
            Sounds.play("Basso")
            Log.write("record: switched to \(to)")
            self.hud.show("No sound from \(from) — using \(to)", recording: true)
            Task { try? await Task.sleep(for: .seconds(2.5)); if case .recording = self.phase { self.syncHUD() } }
        }
        recorder.onNoWorkingMic = { [weak self] tried in
            guard let self else { return }
            Sounds.play("Basso")
            Log.write("record: no working microphone (tried \(tried.joined(separator: ", ")))")
            self.recorder.cancel(); self.recordingStartedAt = nil
            self.phase = .error("no working microphone")
        }
        Log.write("mics: \(MicPicker.describe())")
        // leftover audio goes once it is 24 h old: now, then hourly (the run loop keeps the timer)
        DispatchQueue.global(qos: .utility).async { AudioRecorder.sweep() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { AudioRecorder.sweep() }
        }
        URLCommands.shared.handler = { [weak self] url in self?.handle(url) }
        URLCommands.shared.install()
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Log.write("app: mic request → \(ok)")
            // Build the audio graph now, off the main thread, so the ~10s
            // first-touch cost is paid once at launch instead of on every
            // Fn press. Needs the mic grant first, hence inside this callback.
            guard ok else { return }
            // MUST be the main thread. AVAudioEngine is not thread-safe: building the
            // graph on a background queue and then installing the tap from the main
            // thread (AppState is @MainActor) made installTapOnBus raise an ObjC
            // exception and abort the process — three crashes on 2026-08-22.
            // Measured 70-159ms here, so it is not worth backgrounding.
            DispatchQueue.main.async { [weak self] in
                self?.recorder.prepare()
            }
        }
    }

    func promptPermissions() {
        permissionsOK = Permissions.accessibilityTrusted(prompt: true)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func syncHUD() {
        switch phase {
        case .recording(let locked):
            hud.show(locked ? "Recording (locked)" : "Listening…", recording: true)
        case .processing:
            hud.show("Transcribing…", recording: false)
        case .idle:
            hud.hide()
        case .error(let msg):
            hud.show("Error: \(msg)", recording: false)
            Task { try? await Task.sleep(for: .seconds(4))
                if case .error = self.phase { self.phase = .idle }
            }
        }
    }

    private func startRecording() {
        guard case .idle = phase else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.write("record: BLOCKED — no mic permission")
            phase = .error("no microphone access")
            promptPermissions()
            return
        }
        // Remember where the text should land BEFORE anything shifts focus.
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        // Show the HUD + play the cue IMMEDIATELY so it feels instant — the AVAudioEngine
        // start below has ~150-250 ms of latency we don't want the user waiting on.
        phase = .recording(locked: false)
        Sounds.play("Tink")
        do {
            try recorder.start()
            recordingStartedAt = Date()
            Log.write("record: started (target: \(targetApp), mic: \(recorder.micName))")
        } catch {
            Log.write("record: start FAILED — \(error.localizedDescription)")
            phase = .error(error.localizedDescription)
        }
    }

    private func lockRecording() {
        if case .recording = phase {
            phase = .recording(locked: true)
            Log.write("record: locked")
        }
    }

    private func cancelRecording() {
        guard case .recording = phase else { return }
        recorder.cancel()
        recordingStartedAt = nil
        phase = .idle
        Log.write("record: cancelled")
    }

    private func stopAndProcess() {
        guard case .recording = phase else { return }
        let seconds = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        guard let audioURL = recorder.stop() else {
            // Never silent: a take that vanished without a sound is how lost dictations went unnoticed (2026-10-11).
            Log.write("record: stopped — no usable audio")
            Sounds.play("Basso")
            phase = .error("nothing recorded — say it again")
            return
        }
        Sounds.play("Pop")
        phase = .processing
        Log.write("record: stopped (\(String(format: "%.1f", seconds))s) → pipeline")
        let cleanup = cleanupEnabled
        let app = targetApp
        Task.detached { [weak self] in
            do {
                let result = try await Pipeline.transcribe(audioURL: audioURL, cleanup: cleanup)
                await MainActor.run {
                    guard let self else { return }
                    if result.cleaned.isEmpty {
                        Log.write("pipeline: empty result — nothing inserted")
                        self.phase = .idle
                        return
                    }
                    TextInserter.insert(result.cleaned)
                    self.history.add(raw: result.raw, cleaned: result.cleaned,
                                     seconds: seconds, app: app)
                    Log.write("insert: \(result.cleaned.count) chars → \(app)")
                    self.phase = .idle
                }
            } catch {
                Log.write("pipeline: FAILED — \(error.localizedDescription)")
                await MainActor.run { self?.phase = .error(error.localizedDescription) }
            }
        }
    }
}

extension AppState {
    /// <app>://selftest?seconds=4&mic=<name part> — records from the picker's choice (or a forced starting mic),
    /// transcribes, and LOGS the result; nothing is typed anywhere. Used to verify mic selection and the watchdog.
    func handle(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard AppConfig.current.testHooks else { Log.write("url: ignored (testHooks is off in config.json)"); return }
        if url.host == "polishtest" {
            // <app>://polishtest?text=<transcript>[&out=<candidate>] — runs the AI-polish pass on a given
            // transcript (or, with out=, only the reply check) and LOGS the result; nothing is typed anywhere.
            let raw = q.first { $0.name == "text" }?.value ?? ""
            if let out = q.first(where: { $0.name == "out" })?.value {
                Log.write("polishtest: check → \(Pipeline.notACleanup(out, of: raw).map { "rejected (\($0))" } ?? "accepted")")
            } else {
                Task { let r = await Pipeline.polish(raw); Log.write("polishtest: RESULT \(r.map { "\"\($0)\"" } ?? "nil — local cleanup would insert")") }
            }
            return
        }
        if url.host == "dictate-file" {
            // <app>://dictate-file?path=/abs/audio.wav — runs the whole pipeline on an audio file and pastes the
            // result into the frontmost app, like a real dictation. For testing without a microphone.
            guard case .idle = phase, let path = q.first(where: { $0.name == "path" })?.value else { Log.write("dictate-file: busy or no path"); return }
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            phase = .processing
            let cleanup = cleanupEnabled
            Task.detached { [weak self] in
                do {
                    let r = try await Pipeline.transcribe(audioURL: URL(fileURLWithPath: path), cleanup: cleanup, keepInput: true)
                    await MainActor.run {
                        Log.write("dictate-file: RESULT raw=\"\(r.raw)\" cleaned=\"\(r.cleaned)\"")
                        if !r.cleaned.isEmpty { TextInserter.insert(r.cleaned); self?.history.add(raw: r.raw, cleaned: r.cleaned, seconds: 0, app: app) }
                        self?.phase = .idle
                    }
                } catch { Log.write("dictate-file: FAILED \(error.localizedDescription)"); await MainActor.run { self?.phase = .idle } }
            }
            return
        }
        guard url.host == "selftest" else { Log.write("url: ignored \(url.absoluteString)"); return }
        let seconds = Double(q.first { $0.name == "seconds" }?.value ?? "") ?? 4
        let hint = q.first { $0.name == "mic" }?.value
        let tink = q.contains { $0.name == "tink" }   // mirror a real Fn press: cue sound right before the mic opens
        guard case .idle = phase else { Log.write("selftest: busy"); return }
        Log.write("selftest: start (\(seconds)s, mic hint: \(hint ?? "none")\(tink ? ", tink" : "")) · \(MicPicker.describe())")
        phase = .recording(locked: true)
        if tink { Sounds.play("Tink") }
        do { try recorder.start(preferring: hint) } catch { Log.write("selftest: start FAILED — \(error.localizedDescription)"); phase = .idle; return }
        Log.write("selftest: recording from \(recorder.micName)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard case .recording = self.phase else { Log.write("selftest: ended early (phase \(self.phase))"); return }
            let mic = self.recorder.micName
            guard let audio = self.recorder.stop() else { Log.write("selftest: RESULT no usable audio (mic \(mic))"); self.phase = .idle; return }
            self.phase = .processing
            // keep the self-test's audio for inspection (the pipeline deletes its input)
            let keep = AudioRecorder.tmpDir.appendingPathComponent("selftest-last.caf")
            try? FileManager.default.removeItem(at: keep); try? FileManager.default.copyItem(at: audio, to: keep)
            do {
                let r = try await Pipeline.transcribe(audioURL: audio, cleanup: false)
                Log.write("selftest: RESULT mic=\(mic) transcript=\"\(r.raw)\"")
            } catch { Log.write("selftest: RESULT pipeline failed — \(error.localizedDescription)") }
            self.phase = .idle
        }
    }
}

/// Receives <app>:// URLs (Apple Event), because a MenuBarExtra app has no window to hang .onOpenURL on.
final class URLCommands: NSObject {
    static let shared = URLCommands()
    var handler: ((URL) -> Void)?
    func install() {
        register()
        // SwiftUI installs its own URL handler while the app finishes launching; register again afterwards so ours wins.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in self?.register() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.register() }
    }
    private func register() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        DispatchQueue.main.async { self.handler?(url) }
    }
}

enum Sounds {
    /// NSSound is AppKit and must be used from the main thread.
    ///
    /// It was moved to a background queue on 2026-08-22 after being measured at
    /// 10,156 ms — but that stall was the webcam's broken capture path poisoning the
    /// audio stack, not the sound itself. Backgrounding it merely stopped the cues
    /// from playing at all (AppKit off-main is undefined), which is why the
    /// end-of-recording sound disappeared. Back on main where it belongs.
    static func play(_ name: String) {
        if Thread.isMainThread {
            NSSound(named: NSSound.Name(name))?.play()
        } else {
            DispatchQueue.main.async { NSSound(named: NSSound.Name(name))?.play() }
        }
    }
}
