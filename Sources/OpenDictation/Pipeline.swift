import Foundation

/// audio.caf --ffmpeg--> 16 kHz mono wav (+ loudness gate) --whisper-cli--> raw text
/// --hallucination guard--> --(optional) claude -p--> clean text
/// Pipes only for process stdio (a bad FileHandle can abort() the app).
enum Pipeline {

    struct Result {
        let raw: String
        let cleaned: String
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// ~/.<app>/bin (put a whisper-cli there if you built your own), Homebrew (Apple Silicon and Intel) plus the usual places the `claude` CLI installs itself.
    private static let toolPath = "\(AppConfig.supportDir.path)/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(home)/.local/bin:\(home)/.claude/local:\(home)/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let modelURL = AppConfig.supportDir.appendingPathComponent("models/\(AppConfig.current.model)")
    private static let workDir: URL = {
        let url = AppConfig.supportDir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Whisper's classic hallucinations on silence/noise live in the language pack.
    private static var pack: LanguagePack { LanguagePack.named(AppConfig.current.pack) }

    /// The environment for child processes. If the app was started from inside Claude Code (for example by an
    /// agent running `open`), it inherits CLAUDECODE / CLAUDE_CODE_* variables, and a `claude` child then thinks it is a
    /// nested session and reports "not logged in". Drop them so `claude` behaves as it does in a normal Terminal.
    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { k, _ in
            !(k.hasPrefix("CLAUDE") || k == "AI_AGENT" || k == "AGENT" || k == "AGENT_VOICE")
        }
        env["PATH"] = toolPath
        return env
    }

    /// Is the user's own `claude` CLI installed and signed in? Checked once, then cached.
    /// (`claude auth status` prints JSON with "loggedIn": true. Any failure means "no" and
    /// the app simply uses the local cleanup.)
    static let claudeReady: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "auth", "status"]
        let env = childEnvironment()
        p.environment = env
        let out = Pipe(), errPipe = Pipe(); p.standardOutput = out; p.standardError = errPipe; p.standardInput = Pipe()
        do { try p.run() } catch { Log.write("claude: cannot start (\(error.localizedDescription))"); return false }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); kill.cancel()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let e = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile().prefix(300), as: UTF8.self)
            Log.write("claude: 'auth status' exit \(p.terminationStatus), stderr: \(e), env keys: \(env.keys.sorted().joined(separator: ","))")
            return false
        }
        return (obj["loggedIn"] as? Bool) == true
    }()

    enum PipelineError: LocalizedError {
        case toolFailed(String, String)
        case modelMissing
        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let msg): return "\(tool) failed: \(msg)"
            case .modelMissing: return "Whisper model missing at ~/.\(AppConfig.slug)/models/"
            }
        }
    }

    static func transcribe(audioURL: URL, cleanup: Bool, keepInput: Bool = false) async throws -> Result {
        defer { if !keepInput { try? FileManager.default.removeItem(at: audioURL) } }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw PipelineError.modelMissing }
        let t0 = Date()

        // 1) ffmpeg → 16 kHz mono wav + measure loudness in the same pass
        // In our own work folder, never next to the input: ffmpeg -y would overwrite (and the defer delete) a file
        // there, and dictate-file inputs can sit anywhere.
        let wavURL = workDir.appendingPathComponent("\(UUID().uuidString).16k.wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let ffOut = try await run("ffmpeg", ["ffmpeg", "-y", "-i", audioURL.path,
                                             "-af", "volumedetect",
                                             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                                             wavURL.path], mergeStderr: true)

        // Silence gate. Rejects only when mean AND peak are both low, because a far-away mic
        // (a webcam at arm's length) gives quiet but real speech: mean -46 dB / peak -25 dB
        // must pass. A dead or denied mic reads -91/-91, so requiring both keeps that protection. Peak alone is
        // still not enough on its own — one desk bump beats -35 dB — hence the AND.
        let peak = parseDb(ffOut, key: "max_volume")
        let mean = parseDb(ffOut, key: "mean_volume")
        if let mean, mean < -55, (peak ?? -99) < -35 {
            Log.write("pipeline: silence gate hit (mean \(mean) dB, peak \(peak ?? -99) dB) — no speech")
            return Result(raw: "", cleaned: "")
        }

        // 2) whisper — language from the config ("auto" detects it), no timestamps, quiet
        let rawOut = try await run("whisper-cli", ["whisper-cli", "-m", modelURL.path, "-f", wavURL.path,
                                                   "-l", AppConfig.current.language, "-nt", "-np"])
        let raw = scrub(rawOut)
        Log.write("pipeline: whisper \(String(format: "%.1f", Date().timeIntervalSince(t0)))s → \"\(raw.prefix(80))\"")

        guard !raw.isEmpty, !pack.hallucinations.contains(raw.lowercased()) else {
            Log.write("pipeline: hallucination/empty guard — dropping \"\(raw)\"")
            return Result(raw: raw, cleaned: "")
        }

        // 3a) Instant local cleanup ALWAYS runs (zero cost, ~0 ms). This is the fast default.
        let local = LocalCleanup.clean(raw)

        // Single words ("Tak", "Yes") — done, no LLM.
        let wordCount = local.split(whereSeparator: \.isWhitespace).count
        guard cleanup, wordCount >= 3 else { return Result(raw: raw, cleaned: local) }

        // 3b) OPTIONAL AI polish through the user's own `claude` CLI — best-effort: local text still inserts if the
        // CLI hiccups or the output is not a cleanup.
        return Result(raw: raw, cleaned: await polish(raw) ?? local)
    }

    /// The AI polish on its own; nil when the call fails or its output is not a cleanup of `raw`.
    /// --strict-mcp-config + empty cwd are load-bearing: with the default cwd/config the CLI
    /// ingests MCP servers + any CLAUDE.md chain (~20 s instead of ~3).
    static func polish(_ raw: String) async -> String? {
        guard claudeReady else { return nil }
        guard let template = cleanupPrompt() else { Log.write("pipeline: cleanup prompt missing from the bundle"); return nil }
        do {
            let t1 = Date()
            // Thinking OFF: the CLI turns extended thinking on by default, which made this call
            // take 16–64 s instead of ~2.5 s (A/B on the same prompt).
            // The cleanup rules are the SYSTEM prompt and every tool is off: with Claude Code's own agent
            // prompt in place, a dictation that was itself a request ("check the PDF in my Downloads")
            // got answered instead of cleaned, 5 of 5 replays (2026-10-11). The transcript is the whole
            // user turn and comes first: --tools takes a list and would swallow anything after it.
            let cleaned = try await run("claude", ["claude", "-p", "<transcript>\n" + raw + "\n</transcript>",
                                                  "--model", "haiku", "--system-prompt", template,
                                                  "--tools", "", "--disable-slash-commands", "--no-session-persistence",
                                                  "--strict-mcp-config",
                                                  "--settings", "{\"alwaysThinkingEnabled\":false}"], cwd: workDir)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("pipeline: claude \(String(format: "%.1f", Date().timeIntervalSince(t1)))s → \"\(cleaned.prefix(80))\"")
            if let why = notACleanup(cleaned, of: raw) {
                Log.write("pipeline: claude output rejected (\(why)) — inserting local cleanup")
                return nil
            }
            return cleaned
        } catch {
            Log.write("pipeline: claude failed (\(error.localizedDescription)) — inserting local cleanup")
            return nil
        }
    }

    /// The polish may only clean. A reply, a refusal or commentary brings in words the speaker never said.
    /// Calibrated on 486 real dictations (2026-10-11): cleanups added at most 4 % new words and were never
    /// longer than the transcript; the reply that got pasted was 40 % new words at 3× the length.
    /// Returns why the output was rejected, or nil when it is a cleanup.
    static func notACleanup(_ out: String, of raw: String) -> String? {
        func words(_ s: String) -> [Substring] { s.lowercased().split { !$0.isLetter && !$0.isNumber } }
        let said = Set(words(raw)), outWords = words(out)
        guard !outWords.isEmpty else { return "empty" }
        let novel = Double(outWords.filter { !said.contains($0) }.count) / Double(outWords.count)
        if novel > 0.15 { return "\(Int(novel * 100)) % words never said" }
        if out.count > raw.count + raw.count / 4 + 40 { return "\(raw.count) → \(out.count) chars" }
        return nil
    }

    private static func parseDb(_ output: String, key: String) -> Double? {
        // volumedetect line: "[Parsed_volumedetect_0 @ …] max_volume: -12.3 dB"
        guard let range = output.range(of: "\(key): ") else { return nil }
        let tail = output[range.upperBound...].prefix(12)
        return Double(tail.split(separator: " ").first ?? "")
    }

    /// Strip whisper sound tags like [BLANK_AUDIO], (dzwonek), [MUSIC] + collapse whitespace.
    private static func scrub(_ raw: String) -> String {
        var s = raw
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\*[^\\*]*\\*"] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                let stripped = re.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
                // Accept the strip only when it removed a tag-like token, not real parenthetical speech.
                if stripped.trimmingCharacters(in: .whitespacesAndNewlines).count >= s.count / 2 || s.count < 40 {
                    s = stripped
                }
            }
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanupPrompt() -> String? {
        let url = Bundle.main.url(forResource: "cleanup", withExtension: "md", subdirectory: "prompts")
            ?? Bundle.main.resourceURL?.appendingPathComponent("prompts/cleanup.md")
        guard let url, var s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // optional per-language note, e.g. prompts/pack-pl.md
        if let note = Bundle.main.resourceURL?.appendingPathComponent("prompts/pack-\(AppConfig.current.pack).md"),
           let extra = try? String(contentsOf: note, encoding: .utf8) { s += "\n\n" + extra }
        return s
    }

    @discardableResult
    private static func run(_ label: String, _ argv: [String], stdin: Data? = nil,
                            cwd: URL? = nil, mergeStderr: Bool = false,
                            timeout: TimeInterval = 120) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
            if let cwd { p.currentDirectoryURL = cwd }
            p.environment = childEnvironment()

            let out = Pipe(), err = Pipe(), inPipe = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inPipe

            do { try p.run() } catch { cont.resume(throwing: error); return }

            if let stdin {
                inPipe.fileHandleForWriting.write(stdin)
            }
            try? inPipe.fileHandleForWriting.close()

            let killswitch = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killswitch)

            DispatchQueue.global().async {
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killswitch.cancel()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: mergeStderr ? stdout + "\n" + stderr : stdout)
                } else {
                    cont.resume(throwing: PipelineError.toolFailed(label, String(stderr.suffix(300))))
                }
            }
        }
    }
}
