import AppKit
import SwiftTerm

enum TabStatus: Equatable {
    case starting, working, waiting, idle, shell, exited, archived
    /// Restored at launch but not started yet; starts when you open it.
    case notStarted

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .waiting: "Needs input"
        case .idle: "Idle"
        case .shell: "Shell"
        case .exited: "Exited"
        case .archived: "Archived"
        case .notStarted: "Asleep — uses no memory; starts when you open it"
        }
    }

    /// Claude is running: the green dot, or the spinner/orange dot it turns into while it works or needs you.
    var isActive: Bool { [.starting, .working, .waiting, .idle].contains(self) }
}

/// Finder-style color label for a session.
enum TabColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// What gets written to disk so tabs come back on the next launch.
struct SavedTab: Codable {
    var id: UUID
    var isClaude: Bool
    var sessionId: String?
    var cwd: String
    var customName: String?
    var group: String?
    /// Name shown in "Recently Closed"; not needed to restore.
    var title: String?
    var closedAt: Date?
    var color: TabColor?
    var pinned: Bool?
    var archived: Bool?
    /// When you last sent this session a message; drives "most recent first".
    var lastActive: Date?
    /// Extra claude flags (e.g. --permission-mode auto), reused every time the tab starts.
    var extraArgs: [String]?
    /// Unsent text in Claude's input box, typed back after a restart.
    var draft: String?
    /// The session was running when last saved; started again on the next launch.
    var running: Bool?
}

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    let id: UUID
    let isClaude: Bool
    @Published var sessionId: String?
    @Published var cwd: String
    @Published var customName: String?
    @Published var group: String?
    @Published var color: TabColor?
    @Published var pinned = false
    @Published var archived = false
    @Published var lastActive = Date()
    var extraArgs: [String] = []

    @Published var status: TabStatus = .starting
    @Published var registryName: String?
    @Published var terminalTitle: String?
    @Published var transcript = TranscriptInfo()
    /// Finished or needs input while you were looking elsewhere.
    @Published var needsAttention = false
    /// When it started waiting for you (for ⌘J, oldest first).
    var attentionSince: Date?
    /// The claude process in this tab, once matched in the registry.
    var claudePid: pid_t?
    @Published var memory: UInt64 = 0
    /// What's typed but not sent in Claude's input box (read off the screen).
    @Published var draft: String?
    /// A draft saved last time, waiting to be typed back once Claude is ready.
    var pendingDraft: String?
    /// Was running when the app last quit (see SavedTab.running).
    var wasRunning = false
    /// Typing a draft back is retried until it shows up in the input box.
    var draftRestoreTries = 0
    var lastDraftRestore = Date.distantPast
    @Published var git: GitInfo?

    let terminal: DropTerminalView
    private(set) var shellPid: pid_t = 0
    private(set) var startedAt = Date()
    private var delegateBox: TerminalDelegate?

    init(id: UUID = UUID(), isClaude: Bool, sessionId: String?, cwd: String, customName: String? = nil, group: String? = nil) {
        self.id = id
        self.isClaude = isClaude
        self.sessionId = sessionId
        self.cwd = cwd
        self.customName = customName
        self.group = group
        self.status = isClaude ? .starting : .shell
        terminal = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        Theme.apply(to: terminal)
        let box = TerminalDelegate(tab: self)
        delegateBox = box
        terminal.processDelegate = box
        terminal.claudeActive = { [weak self] in
            guard let self else { return false }
            return [.idle, .working, .waiting].contains(self.status) || (self.isClaude && self.status == .starting)
        }
    }

    convenience init(saved: SavedTab) {
        self.init(id: saved.id, isClaude: saved.isClaude, sessionId: saved.sessionId,
                  cwd: saved.cwd, customName: saved.customName, group: saved.group)
        color = saved.color
        pinned = saved.pinned ?? false
        archived = saved.archived ?? false
        lastActive = saved.lastActive ?? .distantPast
        extraArgs = saved.extraArgs ?? []
        draft = saved.draft
        pendingDraft = saved.draft
        wasRunning = saved.running ?? false
        if archived { status = .archived }
    }

    var saved: SavedTab {
        SavedTab(id: id, isClaude: isClaude, sessionId: sessionId, cwd: cwd, customName: customName, group: group,
                 title: displayName, color: color, pinned: pinned ? true : nil, archived: archived ? true : nil,
                 lastActive: lastActive, extraArgs: extraArgs.isEmpty ? nil : extraArgs, draft: draft,
                 running: status.isActive || status == .shell ? true : nil)
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let t = transcript.title, !t.isEmpty { return t }
        let runningClaude = isClaude || registryName != nil
        if runningClaude, let t = terminalTitle, !t.isEmpty, t != "Claude Code" { return t }
        if let registryName { return registryName }
        return folderName
    }

    var folderName: String { (cwd as NSString).lastPathComponent }
    var shortPath: String { (cwd as NSString).abbreviatingWithTildeInPath }
    /// Sidebar section this tab lives in.
    var groupKey: String { group ?? folderName }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var command = "exec \(shell) -l"
        if isClaude {
            let flags = extraArgs.isEmpty ? DeckSettings.defaultArgs : extraArgs
            var parts = ["claude"] + flags.map(ResumeCommand.shellQuote)
            if DeckSettings.builtInStatusLine, let script = DeckSettings.statusLineScript,
               let json = try? JSONSerialization.data(withJSONObject: [
                   "statusLine": ["type": "command", "command": ResumeCommand.shellQuote(script), "padding": 0],
               ]), let settings = String(data: json, encoding: .utf8) {
                parts += ["--settings", ResumeCommand.shellQuote(settings)]
            }
            // Resume only if there's something to resume; an empty session starts fresh instead.
            if let sessionId, Registry.transcriptExists(sessionId) { parts += ["--resume", ResumeCommand.shellQuote(sessionId)] }
            let claude = parts.joined(separator: " ")
            // Drop into a shell when claude exits so the tab stays usable.
            command = "\(claude); \(command)"
        }
        startedAt = Date()
        status = isClaude ? .starting : .shell
        terminal.startProcess(executable: shell, args: ["-l", "-i", "-c", command],
                              environment: Self.environment(), execName: "-" + (shell as NSString).lastPathComponent,
                              currentDirectory: cwd)
        shellPid = terminal.process.shellPid
    }

    /// Stops the session to free memory; the tab stays and resumes where it was when opened again.
    func sleep() {
        guard status != .notStarted, !archived else { return }
        stashDraft() // typed-but-unsent text comes back on wake
        status = .notStarted
        terminate()
        claudePid = nil
        memory = 0
        needsAttention = false
        terminal.getTerminal().resetToInitialState()
    }

    /// Starts a tab that was restored without starting (lazy launch).
    func startIfNeeded() {
        if status == .notStarted { start() }
    }

    func restart() {
        stashDraft()
        terminate()
        terminal.getTerminal().resetToInitialState()
        start()
    }

    /// Before Claude is stopped: keep what's typed in its input box, to type it back when the session starts again.
    func stashDraft() {
        guard pendingDraft == nil else { return } // an earlier draft hasn't been typed back yet; keep that one
        // Read the box right now: the periodic scan may be a couple of seconds behind your typing.
        if claudePid != nil, status == .idle || status == .working, let text = DraftReader.read(terminal.getTerminal()) {
            draft = text.isEmpty ? nil : text
        }
        pendingDraft = draft
        draftRestoreTries = 0
        lastDraftRestore = .distantPast
    }

    func terminate() {
        let pid = shellPid
        if pid > 0 { killpg(pid, SIGHUP); kill(pid, SIGHUP) }
        terminal.terminate()
        shellPid = 0
        // Collect the exited shell so it doesn't linger as a zombie process.
        if pid > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
            }
        }
    }

    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        // Don't leak a parent Claude Code session's identity into child sessions.
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tabwise"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    fileprivate func titleChanged(_ raw: String) {
        // Claude prefixes the title with a spinner / ✳ glyph; keep only the words.
        let trimmed = raw.drop { !($0.isLetter || $0.isNumber) }
        terminalTitle = trimmed.isEmpty ? nil : String(trimmed)
    }

    fileprivate func processEnded() {
        guard !archived, status != .notStarted else { return } // put to sleep on purpose
        status = .exited
        shellPid = 0
    }
}

private final class TerminalDelegate: LocalProcessTerminalViewDelegate {
    weak var tab: SessionTab?
    init(tab: SessionTab) { self.tab = tab }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { tab?.titleChanged(title) }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.tab?.processEnded() }
        }
    }
}

enum Theme {
    static var fontSize: CGFloat = {
        let s = UserDefaults.standard.double(forKey: "fontSize")
        return s > 0 ? s : 13
    }()

    static func font() -> NSFont {
        NSFont(name: "SF Mono", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static let background = NSColor(srgbRed: 0.105, green: 0.110, blue: 0.130, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1)

    static func apply(to view: LocalProcessTerminalView) {
        view.font = font()
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        view.optionAsMetaKey = false
    }
}
