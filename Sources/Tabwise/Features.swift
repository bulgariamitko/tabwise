import SwiftUI
import AppKit
import Sparkle

// MARK: Settings

/// App-wide preferences (UserDefaults).
enum DeckSettings {
    /// Command every session starts with unless its tab has its own flags.
    static var defaultCommand: String {
        get {
            if let s = UserDefaults.standard.string(forKey: "defaultCommand") { return s }
            let initial = "claude"
            UserDefaults.standard.set(initial, forKey: "defaultCommand")
            return initial
        }
        set { UserDefaults.standard.set(newValue, forKey: "defaultCommand") }
    }

    static var defaultArgs: [String] { ResumeCommand.parse(defaultCommand).args }

    /// Built-in status line (bundled script) for sessions started in the app; on by default.
    static var builtInStatusLine: Bool {
        get { UserDefaults.standard.object(forKey: "builtInStatusLine") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "builtInStatusLine") }
    }

    static var statusLineScript: String? {
        Bundle.main.path(forResource: "statusline", ofType: "sh")
    }

    enum KeepAwakeMode: String, CaseIterable { case working, open, never }

    /// When to stop the Mac from idle-sleeping (battery included).
    static var keepAwake: KeepAwakeMode {
        get { KeepAwakeMode(rawValue: UserDefaults.standard.string(forKey: "keepAwake") ?? "") ?? .working }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keepAwake") }
    }

    /// Start the sessions that were running when the app last quit; on by default.
    static var restartRunning: Bool {
        get { UserDefaults.standard.object(forKey: "restartRunning") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restartRunning") }
    }

    /// Archive running sessions idle for this many days (0 = never).
    static var autoArchiveDays: Int {
        get { UserDefaults.standard.integer(forKey: "autoArchiveDays") }
        set { UserDefaults.standard.set(newValue, forKey: "autoArchiveDays") }
    }
}

struct SavedPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
}

/// Prompts you reuse; the first time, seeded from the prompts you've repeated most across your sessions.
@MainActor
final class PromptLibrary: ObservableObject {
    @Published var prompts: [SavedPrompt] = [] { didSet { save() } }
    private let url = DeckStore.stateURL.deletingLastPathComponent().appendingPathComponent("prompts.json")
    private var loaded = false

    init() {
        if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            prompts = p
            loaded = true
        }
    }

    /// Seed once from history (only if there is no prompts file yet).
    func seedIfNeeded(from items: [HistoryItem]) {
        guard !loaded, !items.isEmpty else { return }
        loaded = true
        var counts: [String: Int] = [:]
        for item in items where !item.isTrivial {
            for p in Set([item.firstPrompt, item.lastPrompt].compactMap { $0 }) where (8...80).contains(p.count) && !p.hasPrefix("/") {
                counts[p, default: 0] += 1
            }
        }
        prompts = counts.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(8).map { SavedPrompt(text: $0.key) }
    }

    private func save() {
        guard loaded || !prompts.isEmpty else { return }
        if let data = try? JSONEncoder().encode(prompts) { try? data.write(to: url, options: .atomic) }
    }
}

struct SettingsView: View {
    @ObservedObject var prompts: PromptLibrary
    let store: DeckStore
    var updater: SPUUpdater? = nil
    @State private var autoUpdate = true
    @ObservedObject var backup: BackupManager
    @State private var backupOn = BackupManager.enabled
    @State private var backupChats = BackupManager.includeConversations
    @State private var destination = BackupManager.destinationName
    @State private var command = DeckSettings.defaultCommand
    @State private var archiveDays = DeckSettings.autoArchiveDays
    @State private var statusLine = DeckSettings.builtInStatusLine
    @State private var keepAwake = DeckSettings.keepAwake
    @State private var restartRunning = DeckSettings.restartRunning
    @State private var newPrompt = ""

    var body: some View {
        Form {
            Section("Sessions") {
                TextField("Default command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { DeckSettings.defaultCommand = command }
                    .onChange(of: command) { _, v in DeckSettings.defaultCommand = v }
                Text("Used for every new, resumed and restored session, unless a tab was opened with its own flags (e.g. via Resume).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reopen running sessions at launch", isOn: $restartRunning)
                    .onChange(of: restartRunning) { _, v in DeckSettings.restartRunning = v }
                Text("Sessions that were running when you quit start again. Off: only the selected tab starts; the rest wait until you open them.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Auto-archive idle sessions", selection: $archiveDays) {
                    Text("Never").tag(0)
                    Text("After 1 day").tag(1)
                    Text("After 3 days").tag(3)
                    Text("After 7 days").tag(7)
                    Text("After 14 days").tag(14)
                    Text("After 30 days").tag(30)
                }
                .onChange(of: archiveDays) { _, v in DeckSettings.autoArchiveDays = v }
                Text("Idle, unpinned sessions you haven't messaged in that long are stopped to free memory. Unarchive resumes them.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Built-in status line", isOn: $statusLine)
                    .onChange(of: statusLine) { _, v in DeckSettings.builtInStatusLine = v }
                Text("Shows model, effort, rate limits, tokens, git and session time under Claude's input box. Applies to sessions started or restarted after changing it. Turn off to use your own Claude Code status line setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup") {
                Toggle("Back up to \(destination)", isOn: $backupOn)
                    .onChange(of: backupOn) { _, v in BackupManager.enabled = v }
                Toggle("Include conversations", isOn: $backupChats)
                    .onChange(of: backupChats) { _, v in BackupManager.includeConversations = v }
                    .disabled(!backupOn)
                if BackupManager.root == nil {
                    Label("iCloud Drive is turned off on this Mac. Turn it on in System Settings → your name → iCloud → iCloud Drive, or choose another folder.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open iCloud Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
                    }
                }
                HStack {
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.message = "Choose where to keep the Tabwise backup (e.g. a Dropbox folder)"
                        if panel.runModal() == .OK, let url = panel.url {
                            BackupManager.customFolder = url.path
                            destination = BackupManager.destinationName
                        }
                    }
                    if BackupManager.customFolder != nil {
                        Button("Use iCloud Drive") { BackupManager.customFolder = nil; destination = BackupManager.destinationName }
                    }
                    Spacer()
                    Button(backup.running ? "Backing Up…" : "Back Up Now") { store.backupConversationsNow() }
                        .disabled(backup.running || BackupManager.root == nil || !backupOn)
                }
                if let last = backup.lastBackup {
                    Text("Last backup \(last.formatted(.relative(presentation: .named))) · \(ByteCountFormatter.string(fromByteCount: backup.lastBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restore Conversations from Backup") { backup.restore {} }
                        .disabled(BackupManager.readManifest() == nil || backup.restoreProgress != nil)
                    if let root = BackupManager.root, FileManager.default.fileExists(atPath: root.path) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }
                }
                Text("Your tabs, names, pins, notes, colors, prompts, drafts and settings are saved every minute; conversations every hour (only what's new is added; one-message automated runs are skipped). On a new Mac, Tabwise offers to restore everything on first launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let updater {
                Section("Updates") {
                    Toggle("Install updates automatically", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, v in updater.automaticallyDownloadsUpdates = v }
                        .onAppear { autoUpdate = updater.automaticallyDownloadsUpdates }
                    Text("New versions download in the background and are installed the next time Tabwise quits or restarts. Tabwise → Check for Updates… checks right away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Power") {
                Picker("Keep Mac awake", selection: $keepAwake) {
                    Text("While a session is working").tag(DeckSettings.KeepAwakeMode.working)
                    Text("While any session is open").tag(DeckSettings.KeepAwakeMode.open)
                    Text("Never").tag(DeckSettings.KeepAwakeMode.never)
                }
                .onChange(of: keepAwake) { _, v in DeckSettings.keepAwake = v }
                Text("Stops the Mac from going to sleep on its own, on battery too. The screen can still turn off. Closing the lid always puts a Mac to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved prompts") {
                ForEach($prompts.prompts) { $p in
                    HStack(alignment: .top) {
                        TextField("Prompt", text: $p.text, axis: .vertical).lineLimit(1...4)
                        Button {
                            prompts.prompts.removeAll { $0.id == p.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { prompts.prompts.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("New prompt", text: $newPrompt, axis: .vertical).lineLimit(1...4)
                    Button("Add") {
                        let t = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        prompts.prompts.append(SavedPrompt(text: t))
                        newPrompt = ""
                    }
                }
                Text("⌃⌘1…⌃⌘9 types a prompt into the current session (press Return to send). Right-click a tab → Send Prompt sends it right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 820)
    }
}

// MARK: Quick switcher

/// ⌘K: jump to any open tab or resume any past session by typing a few letters.
struct QuickSwitcher: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    enum Target: Identifiable {
        case tab(SessionTab), past(HistoryItem)
        var id: String {
            switch self {
            case .tab(let t): "tab-\(t.id)"
            case .past(let h): "past-\(h.id)"
            }
        }
    }

    private var results: [Target] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ hay: String) -> Bool { words.allSatisfy { hay.lowercased().contains($0) } }
        let openIDs = Set(store.tabs.compactMap(\.sessionId))
        let tabs = (store.ordered + store.archivedTabs)
            .filter { matches("\($0.displayName) \($0.cwd) \(store.history.note($0.sessionId) ?? "")") }
            .map(Target.tab)
        let past = history.items
            .filter { !openIDs.contains($0.id) && (!$0.isTrivial || history.isPinned($0.id)) }
            .sorted { (history.isPinned($0.id) ? 1 : 0, $0.lastActive) > (history.isPinned($1.id) ? 1 : 0, $1.lastActive) }
            .filter { matches("\(store.historyName($0)) \($0.cwd ?? "") \(history.note($0.id) ?? "")") }
            .map(Target.past)
        return Array((tabs + past).prefix(60))
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { open(list) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, target in
                        row(target)
                            .padding(.vertical, 2)
                            .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { highlighted = i; open(list) }
                            .id(i)
                    }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true; history.refresh() }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    @ViewBuilder private func row(_ target: Target) -> some View {
        switch target {
        case .tab(let t):
            HStack(spacing: 8) {
                StatusIndicator(status: t.status, attention: t.needsAttention).frame(width: 14)
                VStack(alignment: .leading) {
                    Text(t.displayName).lineLimit(1)
                    FolderLabel(text: FolderColors.shortPath(t.cwd), color: store.folderColors.color(for: t.cwd)).font(.caption)
                }
                Spacer()
                Text(t.archived ? "archived" : "open").font(.caption).foregroundStyle(.tertiary)
            }
        case .past(let h):
            HStack(spacing: 8) {
                Image(systemName: history.isPinned(h.id) ? "pin.fill" : "clock").foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading) {
                    Text(store.historyName(h)).lineLimit(1)
                    FolderLabel(text: h.folderName, color: store.folderColors.color(for: h.cwd)).font(.caption)
                }
                Spacer()
                Text(TabRow.relative(h.lastActive)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func open(_ list: [Target]) {
        guard list.indices.contains(highlighted) else { return }
        switch list[highlighted] {
        case .tab(let t):
            store.sidebarMode = .open
            if t.archived { store.unarchive(t) } else { store.selectedID = t.id }
        case .past(let h):
            store.resumeHistory(h)
        }
        dismiss()
    }
}

// MARK: Send to several sessions

struct BroadcastSheet: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var prompts: PromptLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var picked = Set<UUID>()

    private var targets: [SessionTab] { store.ordered.filter { [.idle, .working, .waiting].contains($0.status) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to several sessions").font(.title2.bold())
            HStack {
                Text("Prompt").font(.headline)
                Spacer()
                if !prompts.prompts.isEmpty {
                    Menu("Saved prompts") {
                        ForEach(prompts.prompts) { p in Button(String(p.text.prefix(60))) { text = p.text } }
                    }
                    .fixedSize()
                }
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Button("Idle ones") { picked = Set(targets.filter { $0.status == .idle }.map(\.id)) }
                Button(picked.count == targets.count ? "None" : "All") {
                    picked = picked.count == targets.count ? [] : Set(targets.map(\.id))
                }
            }
            List(targets) { tab in
                Toggle(isOn: Binding(get: { picked.contains(tab.id) },
                                     set: { if $0 { picked.insert(tab.id) } else { picked.remove(tab.id) } })) {
                    HStack {
                        StatusIndicator(status: tab.status, attention: tab.needsAttention).frame(width: 14)
                        Text(tab.displayName).lineLimit(1)
                        Spacer()
                        Text(tab.folderName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 200)
            if targets.contains(where: { picked.contains($0.id) && $0.status == .working }) {
                Label("Sessions that are working will get it queued as their next message.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send to \(picked.count)") {
                    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    for tab in targets where picked.contains(tab.id) { tab.terminal.insert(message, submit: true) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }
}

// MARK: Folder colors

/// Every folder gets its own color automatically — the next unused one from a high-contrast palette, kept
/// from then on — and you can override it per folder.
@MainActor
final class FolderColors: ObservableObject {
    @Published private(set) var overrides: [String: String] =
        UserDefaults.standard.dictionary(forKey: "folderColors") as? [String: String] ?? [:]

    /// Ordered so that consecutive colors differ as much as possible.
    private static let palette: [Color] = [
        Color(hue: 0.60, saturation: 0.55, brightness: 1.0),   // blue
        Color(hue: 0.08, saturation: 0.70, brightness: 1.0),   // orange
        Color(hue: 0.36, saturation: 0.55, brightness: 0.90),  // green
        Color(hue: 0.90, saturation: 0.50, brightness: 1.0),   // pink
        Color(hue: 0.48, saturation: 0.60, brightness: 0.90),  // teal
        Color(hue: 0.14, saturation: 0.65, brightness: 1.0),   // yellow
        Color(hue: 0.76, saturation: 0.50, brightness: 1.0),   // purple
        Color(hue: 0.00, saturation: 0.60, brightness: 1.0),   // red
        Color(hue: 0.54, saturation: 0.60, brightness: 1.0),   // cyan
        Color(hue: 0.24, saturation: 0.60, brightness: 0.95),  // lime
        Color(hue: 0.68, saturation: 0.50, brightness: 1.0),   // indigo
        Color(hue: 0.83, saturation: 0.55, brightness: 1.0),   // magenta
    ]
    /// Automatic assignments (folder → palette index); not published, written as folders first appear.
    private var assigned: [String: Int] = UserDefaults.standard.dictionary(forKey: "folderColorSlots") as? [String: Int] ?? [:]

    func color(for path: String?) -> Color {
        guard let path else { return .gray }
        if let name = overrides[path], let c = TabColor(rawValue: name) { return c.swiftUI }
        if let slot = assigned[path] { return Self.palette[slot % Self.palette.count] }
        let slot = assigned.count
        assigned[path] = slot
        UserDefaults.standard.set(assigned, forKey: "folderColorSlots")
        return Self.palette[slot % Self.palette.count]
    }

    /// "~/Library/CloudStorage/Dropbox/nima" → "Dropbox/nima".
    static func shortPath(_ path: String) -> String {
        var p = (path as NSString).abbreviatingWithTildeInPath
        for prefix in ["~/Library/CloudStorage/", "~/Library/Mobile Documents/com~apple~CloudDocs/"] where p.hasPrefix(prefix) {
            p = String(p.dropFirst(prefix.count))
            if prefix.contains("CloudDocs") { p = "iCloud/" + p }
        }
        return p
    }

    func override(for path: String?) -> TabColor? { path.flatMap { overrides[$0] }.flatMap(TabColor.init(rawValue:)) }

    func set(_ color: TabColor?, for path: String) {
        overrides[path] = color?.rawValue
        UserDefaults.standard.set(overrides, forKey: "folderColors")
    }

}

/// A folder path drawn as a tinted pill in the folder's color.
struct FolderLabel: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// "Folder Color" submenu shared by the Open and All Sessions lists.
struct FolderColorMenu: View {
    @ObservedObject var colors: FolderColors
    let path: String?
    var body: some View {
        if let path {
            Menu("Folder Color") {
                Button {
                    colors.set(nil, for: path)
                } label: { Label("Automatic", systemImage: colors.override(for: path) == nil ? "checkmark" : "wand.and.stars") }
                Divider()
                ForEach(TabColor.allCases) { c in
                    Button { colors.set(c, for: path) } label: {
                        Label(c.name, systemImage: colors.override(for: path) == c ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(c.swiftUI)
                }
            }
        }
    }
}

// MARK: Welcome

/// First launch on a Mac with no tabs: checks for Claude Code and gets you to your first session.
struct WelcomeView: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    @State private var claudePath: String?? = .none   // nil = checking, .some(nil) = not installed
    @State private var running = 0

    private static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Tabwise").font(.largeTitle.bold())
                    Text("All your Claude Code sessions in one window.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                tip("rectangle.stack", "Every session is a tab on the left, with live status: working, waiting for you, or idle.")
                tip("bell.badge", "Get notified when a session finishes or needs input. ⌘J jumps to it.")
                tip("clock.arrow.circlepath", "All Sessions lists every past conversation — search, pin and resume any of them.")
                tip("externaldrive.badge.icloud", "Tabs, drafts and conversations come back after quitting, restarting, or on a new Mac.")
            }
            Divider()
            switch claudePath {
            case .none:
                HStack { ProgressView().controlSize(.small); Text("Looking for Claude Code…") }
            case .some(.some(let path)):
                Label("Claude Code found at \((path as NSString).abbreviatingWithTildeInPath)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .some(.none):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Claude Code isn't installed yet.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Install it by running this in a Terminal (or in a Tabwise shell tab, ⌥⌘T):").font(.callout)
                    HStack {
                        Text(Self.installCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.installCommand, forType: .string)
                        }
                    }
                }
            }
            HStack {
                if running > 0 {
                    Button("Import \(running) Running Session\(running == 1 ? "" : "s")…") { dismiss(); store.showImport = true }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start a Session…") { dismiss(); AppActions.newSession(store) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(claudePath == .some(nil))
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            running = store.importCandidates().count
            claudePath = .some(await Task.detached { Self.findClaude() }.value)
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22) }
    }

    /// Looks for `claude` the way a new tab would: through the user's login shell.
    nonisolated static func findClaude() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") ? path : nil
    }
}
