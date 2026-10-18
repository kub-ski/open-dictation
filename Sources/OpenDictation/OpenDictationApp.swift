import SwiftUI

@main
struct OpenDictationApp: App {
    @StateObject private var state = AppState()

    init() {
        // `OpenDictation --check` runs the built-in self-check (no UI) and exits.
        if CommandLine.arguments.contains("--check") { exit(SelfCheck.run()) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .environmentObject(state.history)
        } label: {
            Image(systemName: state.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("\(AppConfig.displayName) — History", id: "history") {
            HistoryView()
                .environmentObject(state.history)
        }
        .defaultSize(width: 640, height: 480)
    }
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var history: HistoryStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.statusLine, systemImage: state.menuIcon)
                .font(.headline)

            if !state.permissionsOK {
                Button {
                    state.promptPermissions()
                } label: {
                    Label("Grant permissions…", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.red)
                }
            }

            Divider()

            if history.entries.isEmpty {
                Text("No dictations yet — hold \(Hotkey.all[AppConfig.current.hotkey]?.label ?? "Fn") and talk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.entries.prefix(3)) { e in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.cleaned, forType: .string)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.cleaned)
                                .lineLimit(2)
                                .font(.callout)
                            Text(e.date.formatted(date: .omitted, time: .shortened) + " · click to copy")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Open history…") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()
            Toggle(state.claudeAvailable ? "AI polish (your Claude, a few seconds slower)" : "AI polish (needs the claude CLI, signed in)",
                   isOn: $state.cleanupEnabled)
                .toggleStyle(.checkbox)
                .disabled(!state.claudeAvailable)
            Text("Hold \(Hotkey.all[AppConfig.current.hotkey]?.label ?? "Fn") = talk · tap twice = lock · tap = stop")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Quit \(AppConfig.displayName)") { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(width: 280)
    }
}

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var search = ""

    private var filtered: [DictationEntry] {
        guard !search.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.cleaned.localizedCaseInsensitiveContains(search) ||
            $0.raw.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                ContentUnavailableView("No dictations yet",
                                       systemImage: "mic",
                                       description: Text("Hold your hotkey and start talking — everything you dictate lands here."))
            } else {
                List(filtered) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("→ \(e.app)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(String(format: "%.0fs", e.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.cleaned, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                        Text(e.cleaned)
                            .font(.body)
                            .textSelection(.enabled)
                        if e.raw != e.cleaned {
                            Text(e.raw)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $search, prompt: "Search dictations")
        .toolbar {
            Button("Clear history") { history.clear() }
                .disabled(history.entries.isEmpty)
        }
        .navigationTitle("\(AppConfig.displayName) — History")
    }
}
