import AVFoundation
import CoreAudio

/// Mic capture → .caf in ~/.<app>/tmp (native format; ffmpeg downsamples to whisper's 16 kHz mono later).
///
/// Since 2026-09-30 this records through AVCaptureSession on a microphone chosen by MicPicker, with a
/// watchdog that switches mic when the current one delivers no sound. Why not AVAudioEngine any more:
///
///   - AVAudioEngine can only record the system default input. Pointing it at another device
///     (kAudioOutputUnitProperty_CurrentDevice or auAudioUnit.setDeviceID) makes engine.start() fail with
///     -10868 FormatNotSupported on non-default mics.
///   - The default input is whatever macOS last switched to, such as headphones that are busy with another
///     device. That can deliver digital silence, and a silent take used to be thrown away with no warning.
///   - AVCaptureSession takes any device by its UID without touching the system default.
///
/// Formats are never forced: the writer is built from the first buffer's own format (the August lesson).
/// If a later buffer arrives in a different format, the take continues in a new segment (2026-10-11):
/// some USB webcams sometimes send its first buffer as Int16 interleaved and the rest as Float32, and every
/// write after that first buffer used to fail — the take was thrown away as "no usable audio".
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Main thread. A mic delivered no sound and the recorder moved to the next one.
    var onSwitch: ((_ from: String, _ to: String) -> Void)?
    /// Main thread. Every candidate was silent.
    var onNoWorkingMic: ((_ tried: [String]) -> Void)?
    private(set) var micName = "?"

    static let tmpDir: URL = {
        let url = AppConfig.supportDir
            .appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Deletes leftover audio once it is a day old (2026-10-11: 1.84 GB had piled up since July).
    /// A normal take cleans up after itself, so anything here that old is from a crash, a quit mid-take
    /// or a failure; the 24 h are the window to recover it. A take in progress is written to constantly
    /// and never qualifies. Keep test clips elsewhere.
    static func sweep(olderThan age: TimeInterval = 24 * 3600) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: Array(keys)) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        var count = 0, bytes = 0
        for url in items {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                  let modified = v.contentModificationDate, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { count += 1; bytes += v.fileSize ?? 0 }
        }
        if count > 0 { Log.write("tmp: deleted \(count) file(s) older than 24 h, \(bytes / 1_000_000) MB freed") }
    }

    private let queue = DispatchQueue(label: "opendictation.capture")          // sample buffers + writer
    private let sessionQueue = DispatchQueue(label: "opendictation.session")   // start/stopRunning block; never on the buffer queue
    private var session: AVCaptureSession?
    private var candidates: [MicPicker.Mic] = []
    private var tried: [String] = []
    private var watchdog: Timer?
    private var segmentStart = Date()
    private var lastFrames: Int64 = 0
    private var lastCheck = Date()
    private var settled = false   // the first 0.3 s are ignored: some Bluetooth headsets send one non-zero blip, then zeros

    // capture-queue state (segments too: the capture queue starts a new one when the format changes)
    private var segments: [URL] = []
    private var micFirstSegment = 0   // the current mic's first segment; a mic that never delivered sound loses them all
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private var peakSinceStart: Float = 0
    private var windowPeak: Float = 0
    // diagnostics (2026-10-11): takes with audio flowing ended "no usable audio"; logged per segment
    private var buffers = 0, writerOpens = 0, writeFails = 0, lateBuffers = 0
    private var firstFail: String?, firstFormat: String?
    private var stopping = false

    /// Kept so AppState's launch call stays valid; the session is built per press.
    func prepare() {}

    func start(preferring hint: String? = nil) throws {
        candidates = MicPicker.candidates(preferring: hint)
        tried = []; queue.sync { segments = [] }
        guard !candidates.isEmpty else {
            throw NSError(domain: "OpenDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone found"])
        }
        try open(candidates.removeFirst())
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.check() }
    }

    private func open(_ mic: MicPicker.Mic) throws {
        guard let device = AVCaptureDevice(uniqueID: mic.uid) else {
            throw NSError(domain: "OpenDictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(mic.name) unavailable"])
        }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw NSError(domain: "OpenDictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot use \(mic.name)"]) }
        s.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { throw NSError(domain: "OpenDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot read \(mic.name)"]) }
        s.addOutput(output)
        queue.sync { file = nil; frames = 0; peakSinceStart = 0; windowPeak = 0
                     buffers = 0; writerOpens = 0; writeFails = 0; lateBuffers = 0; firstFail = nil; firstFormat = nil; stopping = false
                     micFirstSegment = segments.count; segments.append(Self.segmentURL(segments.count)) }
        micName = mic.name; tried.append(mic.name)
        session = s
        segmentStart = Date(); lastCheck = segmentStart; lastFrames = 0; settled = false
        sessionQueue.async { s.startRunning() }   // blocking call; kept off the main thread and the buffer queue
    }

    // MARK: capture queue

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        pcm.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList) == noErr else { return }
        buffers += 1; if stopping { lateBuffers += 1 }
        if firstFormat == nil { firstFormat = Self.describe(fmt) }
        if let f = file, Self.describe(f.processingFormat) != Self.describe(fmt) {
            // the device changed format mid-stream: a writer only takes its own format (-50 otherwise), so close it
            // and carry on in a new segment; stop() joins the pieces. Compared on rate/channels/sample type/layout
            // only — AVAudioFormat equality also weighs channel-layout metadata that the writer itself ignores.
            Log.write("record: format changed \(Self.describe(f.processingFormat)) → \(Self.describe(fmt)) — new segment")
            file = nil
            segments.append(Self.segmentURL(segments.count))
        }
        if file == nil, let url = segments.last {
            // the writer takes the buffer's own format, so file and data can never disagree
            file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            writerOpens += 1
            if file == nil { Log.write("record: could not open \(url.lastPathComponent) for writing") }
        }
        do { try file?.write(from: pcm) } catch {
            writeFails += 1
            if firstFail == nil { firstFail = "\((error as NSError).code) buf \(Self.describe(fmt)) vs file \(file.map { Self.describe($0.processingFormat) } ?? "-")" }
        }
        let p = Self.peak(pcm)
        frames += Int64(n); peakSinceStart = max(peakSinceStart, p); windowPeak = max(windowPeak, p)
    }

    private static func peak(_ b: AVAudioPCMBuffer) -> Float {
        let f = b.format, chans = f.isInterleaved ? 1 : Int(f.channelCount)
        let len = Int(b.frameLength) * (f.isInterleaved ? Int(f.channelCount) : 1)
        var p: Float = 0
        switch f.commonFormat {
        case .pcmFormatFloat32: if let d = b.floatChannelData { for c in 0..<chans { for i in 0..<len { p = max(p, abs(d[c][i])) } } }
        case .pcmFormatInt16:   if let d = b.int16ChannelData { for c in 0..<chans { for i in 0..<len { p = max(p, abs(Float(d[c][i]) / 32768)) } } }
        case .pcmFormatInt32:   if let d = b.int32ChannelData { for c in 0..<chans { for i in 0..<len { p = max(p, abs(Float(d[c][i]) / 2147483648)) } } }
        default: p = 1   // unknown layout: never call it dead
        }
        return p
    }

    private static func segmentURL(_ index: Int) -> URL {
        tmpDir.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970))-\(index).caf")
    }

    private static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))Hz/\(f.channelCount)ch/\(f.commonFormat.rawValue)\(f.isInterleaved ? "i" : "n")"
    }

    // MARK: watchdog (main thread)

    /// Digital silence is exactly zero. A working mic's noise floor sits far above 1e-5 (-100 dB),
    /// so a pause in speech never trips this; a dead or busy device does.
    private func check() {
        let now = Date()
        let (f, pWin): (Int64, Float) = queue.sync { (frames, windowPeak) }
        if !settled && now.timeIntervalSince(segmentStart) >= 0.3 {
            settled = true; queue.sync { windowPeak = 0 }   // forget the opening transient
        } else if settled && lastFrames == 0 && now.timeIntervalSince(segmentStart) >= 0.6 {
            // first verdict at 0.6 s, on 0.3–0.6 s: nothing arrived, or only zeros
            if f == 0 || pWin < 1e-5 { switchMic(reason: f == 0 ? "no audio" : "silent"); return }
            lastFrames = f; lastCheck = now; queue.sync { windowPeak = 0 }
        } else if lastFrames > 0 && now.timeIntervalSince(lastCheck) >= 1.0 {
            // mid-take: the stream stalled or went to zeros for a full second
            if f == lastFrames || pWin < 1e-5 { switchMic(reason: f == lastFrames ? "stalled" : "went silent"); return }
            lastFrames = f; lastCheck = now; queue.sync { windowPeak = 0 }
        }
    }

    private func switchMic(reason: String) {
        let from = micName
        let hadSound = lastFrames > 0   // passed the 0.6 s verdict = real audio in this segment; otherwise drop it
        closeSession()
        if !hadSound {   // keep speech, drop silence: everything this mic wrote
            queue.sync { () -> [URL] in let dead = Array(segments[micFirstSegment...]); segments.removeSubrange(micFirstSegment...); return dead }
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }
        Log.write("record: mic \(from) \(reason)")
        while !candidates.isEmpty {
            let next = candidates.removeFirst()
            do { try open(next); onSwitch?(from, next.name); return }
            catch { Log.write("record: \(next.name) failed to open — \(error.localizedDescription)") }
        }
        watchdog?.invalidate(); watchdog = nil
        onNoWorkingMic?(tried)
    }

    private func closeSession() {
        if let s = session {
            queue.sync { stopping = true }
            sessionQueue.sync { s.stopRunning() }; queue.sync { file = nil }   // stop, then flush + close the writer
            let d = queue.sync { "buffers \(buffers), frames \(frames), peak \(String(format: "%.0f", 20 * log10(max(peakSinceStart, 1e-9)))) dB, fmt \(firstFormat ?? "-"), writer opens \(writerOpens), write fails \(writeFails)\(firstFail.map { " (first: \($0))" } ?? ""), late \(lateBuffers)" }
            Log.write("record: closed \(micName) — \(d)")
            let q = queue   // buffers that arrive after the close would reopen the writer: count them a moment later
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                let (late, opens, open) = q.sync { (self.lateBuffers, self.writerOpens, self.file != nil) }
                if late > 0 || open { Log.write("record: after close — late buffers \(late), writer opens \(opens), writer open \(open)") }
            }
        }
        session = nil
    }

    // MARK: stop / cancel

    /// Stop and hand back the audio file (nil if nothing usable was captured).
    func stop() -> URL? {
        watchdog?.invalidate(); watchdog = nil
        closeSession()
        let segs = queue.sync { () -> [URL] in defer { segments = [] }; return segments }
        Log.write("record: segments " + segs.map { "\($0.lastPathComponent)=\(((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? -1)) B" }.joined(separator: ", "))
        let usable = segs.filter { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 8_000 }
        for s in segs where !usable.contains(s) { try? FileManager.default.removeItem(at: s) }
        guard !usable.isEmpty else { return nil }
        return usable.count == 1 ? usable[0] : Self.merge(usable)
    }

    func cancel() {
        watchdog?.invalidate(); watchdog = nil
        closeSession()
        queue.sync { () -> [URL] in defer { segments = [] }; return segments }.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// A take that switched mic mid-way is in pieces with possibly different formats; ffmpeg joins them.
    private static func merge(_ parts: [URL]) -> URL {
        let out = tmpDir.appendingPathComponent("dictation-\(Int(Date().timeIntervalSince1970))-merged.caf")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + parts.flatMap { ["-i", $0.path] }
            + ["-filter_complex", parts.indices.map { "[\($0):a]" }.joined() + "concat=n=\(parts.count):v=0:a=1", "-ac", "1", "-ar", "48000", out.path]
        do { try p.run(); p.waitUntilExit() } catch {}
        if p.terminationStatus == 0 { parts.forEach { try? FileManager.default.removeItem(at: $0) }; return out }
        Log.write("record: merge failed — keeping the last segment")
        return parts.last!
    }
}
