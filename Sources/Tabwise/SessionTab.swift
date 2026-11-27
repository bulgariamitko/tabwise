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
    /// Claude tab (false: a plain shell, or another agent; see `agent`).
    var isClaude: Bool
    /// Codex or Antigravity; nil for Claude and shell tabs, which `isClaude` tells apart (files from older versions).
    var agent: Agent?
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
    /// Messages stacked with ⌘↩, sent one by one as Claude finishes each turn (paused after a restart).
    var queued: [String]?
    /// The session was running when last saved; started again on the next launch.
    var running: Bool?
    /// The tier the model router has the tab on ("simple" / "everyday" / "complex"; nil: none yet).
    var tier: String?
    /// The model and effort you set for this session yourself: a name, "-" for the agent's own setting, nil
    /// for automatic (the router's choice where it's on).
    var model: String?
    var effort: String?
    /// Messages to send at a set time (right-click → Schedule Message…).
    var scheduled: [ScheduledMessage]?
}

/// A message to send to a session at a set time. When it's due it joins the session's queue, so it waits for
/// a turn in progress like any queued message.
struct ScheduledMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Date
    var text: String
}

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    let id: UUID
    /// The agent this tab runs, or nil for a plain shell.
    let agent: Agent?
    var isClaude: Bool { agent == .claude }
    var isAgent: Bool { agent != nil }
    @Published var sessionId: String?
    @Published var cwd: String
    @Published var customName: String?
    @Published var group: String?
    @Published var color: TabColor?
    @Published var pinned = false
    @Published var archived = false
    @Published var lastActive = Date()
    var extraArgs: [String] = []
    /// This session's model and effort: automatic, the agent's own, or what you set (tab menu → Model / Effort).
    @Published var modelPick = Pick.auto
    @Published var effortPick = Pick.auto
    /// The tier the model router has the tab on; nil while nothing was chosen for it yet.
    @Published var tier: Tier?
    /// Why the router chose that tier (sidebar tooltip).
    @Published var routeNote: String?
    /// A message handed to the agent as it starts: the router restarted it on another model to send this.
    var firstPrompt: String?
    /// You changed the tab's model while the agent was working: restart on it once the turn ends.
    var rerouteWhenIdle = false
    /// Codex / Antigravity were told to start a new conversation ("/new", "/clear") at this time. Which one the
    /// tab is in shows only once they write it, so until then the tab has no conversation to resume.
    var conversationResetAt: Date?

    @Published var status: TabStatus = .starting
    @Published var registryName: String?
    @Published var terminalTitle: String?
    @Published var transcript = TranscriptInfo()
    /// Finished or needs input while you were looking elsewhere.
    @Published var needsAttention = false
    /// When it started waiting for you (for ⌘J, oldest first).
    var attentionSince: Date?
    /// The agent's process in this tab, once found (Claude: matched in its registry).
    var claudePid: pid_t?
    /// Codex / Antigravity: start with the folder's latest conversation (once; then the tab knows its session).
    var continueLatest = false
    @Published var memory: UInt64 = 0
    /// What's typed but not sent in Claude's input box (read off the screen).
    @Published var draft: String?
    /// You approved the draft: press Return for you as soon as Claude finishes its turn.
    @Published var sendWhenDone = false
    /// Messages lifted out of the input box with ⌘↩, typed in and sent one per turn, oldest first.
    @Published var queued: [String] = []
    /// The queue waits for you: the last turn failed, the Mac slept mid-turn, or the app restarted. ⌘↩ resumes.
    @Published var queuePaused = false { didSet { if !queuePaused { queuePauseReason = nil } } }
    /// Why the queue paused, in a few words ("the last turn failed").
    @Published var queuePauseReason: String?
    /// What the next queued message is waiting for right now ("something is typed in the input box").
    @Published var queueWait: String?
    /// Messages to send at a set time, soonest first.
    @Published var scheduled: [ScheduledMessage] = []
    /// When the last queued message went out; the next one waits until Claude has worked on it.
    var queueSentAt: Date?
    /// The queue is open for editing: hold it until the window closes.
    var queueEditing = false
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

    init(id: UUID = UUID(), agent: Agent?, sessionId: String?, cwd: String, customName: String? = nil, group: String? = nil) {
        self.id = id
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.customName = customName
        self.group = group
        self.status = agent != nil ? .starting : .shell
        terminal = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminal.autoresizingMask = [.width, .height]
        Theme.apply(to: terminal)
        let box = TerminalDelegate(tab: self)
        delegateBox = box
        terminal.processDelegate = box
        terminal.claudeActive = { [weak self] in
            guard let self else { return false }
            return [.idle, .working, .waiting].contains(self.status) || (self.isAgent && self.status == .starting)
        }
        terminal.routeReturn = { [weak self] in
            guard let self else { return false }
            return Self.onReturn?(self) ?? false
        }
    }

    /// Return pressed in a tab's terminal; the store's model router answers whether it took the message over.
    static var onReturn: ((SessionTab) -> Bool)?

    convenience init(saved: SavedTab) {
        self.init(id: saved.id, agent: saved.agent ?? (saved.isClaude ? .claude : nil), sessionId: saved.sessionId,
                  cwd: saved.cwd, customName: saved.customName, group: saved.group)
        color = saved.color
        pinned = saved.pinned ?? false
        archived = saved.archived ?? false
        lastActive = saved.lastActive ?? .distantPast
        extraArgs = saved.extraArgs ?? []
        draft = saved.draft
        pendingDraft = saved.draft
        queued = saved.queued ?? []
        queuePaused = !queued.isEmpty
        if queuePaused { queuePauseReason = "Tabwise restarted" }
        scheduled = saved.scheduled ?? []
        wasRunning = saved.running ?? false
        tier = saved.tier.flatMap(Tier.init(rawValue:))
        modelPick = Pick(saved: saved.model)
        effortPick = Pick(saved: saved.effort)
        if archived { status = .archived }
    }

    var saved: SavedTab {
        SavedTab(id: id, isClaude: isClaude, agent: isClaude ? nil : agent, sessionId: sessionId, cwd: cwd, customName: customName, group: group,
                 title: displayName, color: color, pinned: pinned ? true : nil, archived: archived ? true : nil,
                 lastActive: lastActive, extraArgs: extraArgs.isEmpty ? nil : extraArgs, draft: draft,
                 queued: queued.isEmpty ? nil : queued,
                 running: status.isActive || status == .shell ? true : nil, tier: tier?.rawValue,
                 model: modelPick.saved, effort: effortPick.saved, scheduled: scheduled.isEmpty ? nil : scheduled)
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let t = transcript.title, !t.isEmpty { return t }
        let runningAgent = isAgent || registryName != nil
        if runningAgent, let t = terminalTitle, !t.isEmpty, t != "Claude Code" { return t }
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
        var extraEnv: [String: String] = [:]
        let routed = routedFlags
        let prompt = firstPrompt
        firstPrompt = nil
        if isClaude {
            var flags = extraArgs.isEmpty ? DeckSettings.defaultArgs : extraArgs
            // The router's model and effort replace the ones in the tab's own flags.
            if let routed { flags = Self.dropping(routed.filter { $0.hasPrefix("--") }, from: flags) + routed }
            var parts = ["claude"] + flags.map(ResumeCommand.shellQuote)
            var settings: [String: Any] = [:]
            if DeckSettings.builtInStatusLine, let script = DeckSettings.statusLineScript {
                settings["statusLine"] = ["type": "command", "command": ResumeCommand.shellQuote(script), "padding": 0]
            }
            // The ask-on-deny mod reads these to let calls auto mode blocked through without asking: the switch
            // files are read on each block, so changing the setting reaches the running session.
            extraEnv["TABWISE_AUTO_ALLOW_DIR"] = DeckSettings.autoAllowDir.path
            extraEnv["TABWISE_TAB_ID"] = id.uuidString
            // The mod writes its log of what it let through here (right-click → Auto-Allowed Commands…).
            try? FileManager.default.createDirectory(at: DeckSettings.autoAllowDir, withIntermediateDirectories: true)
            if !settings.isEmpty, let json = try? JSONSerialization.data(withJSONObject: settings),
               let text = String(data: json, encoding: .utf8) {
                parts += ["--settings", ResumeCommand.shellQuote(text)]
            }
            // Enabled mods, as flags: a CLAUDE_CODE_PLUGIN_DIRS in the user's settings.json would override an env var.
            for path in Mods.toLoad() { parts += ["--plugin-dir", ResumeCommand.shellQuote(path)] }
            // Resume only if there's something to resume; an empty session starts fresh instead.
            if let sessionId, Registry.transcriptExists(sessionId) { parts += ["--resume", ResumeCommand.shellQuote(sessionId)] }
            if let prompt { parts += ["--", ResumeCommand.shellQuote(prompt)] }
            let claude = parts.joined(separator: " ")
            // Drop into a shell when claude exits so the tab stays usable.
            command = "\(claude); \(command)"
        } else if let agent {
            var start = agent.startCommand(sessionId: sessionId, cwd: cwd, continueLatest: continueLatest)
            if let routed, !routed.isEmpty { start += " " + routed.map(ResumeCommand.shellQuote).joined(separator: " ") }
            if let extra = ProcessInfo.processInfo.environment["TABWISE_TEST_\(agent.rawValue.uppercased())_ARGS"] { start += " " + extra } // test hook
            // Claude's MCP servers for this folder (~/.claude.json is local; .mcp.json is read bounded).
            let servers = MCPShare.enabled ? MCPShare.claudeServers(cwd: cwd) : []
            if agent == .codex, !servers.isEmpty {
                let flags = MCPShare.codexFlags(servers)
                start += " " + flags.args.map(ResumeCommand.shellQuote).joined(separator: " ")
                extraEnv = flags.env
            } else if agent == .antigravity {
                MCPShare.syncAntigravity(servers)
            }
            if let prompt {
                start += (agent == .codex ? " -- " : " --prompt-interactive ") + ResumeCommand.shellQuote(prompt)
            }
            command = "\(start); \(command)"
        }
        startedAt = Date()
        status = isAgent ? .starting : .shell
        terminal.startProcess(executable: shell, args: ["-l", "-i", "-c", command],
                              environment: Self.environment(extraEnv), execName: "-" + (shell as NSString).lastPathComponent,
                              currentDirectory: cwd)
        shellPid = terminal.process.shellPid
    }

    /// The launch flags for this session's model and effort (yours, or the router's); nil for a shell.
    private var routedFlags: [String]? {
        agent.map { Router.flags($0, tier: tier, model: modelPick, effort: effortPick) }
    }

    /// `flags` without the named ones and their values ("--model opus", "--model=opus").
    static func dropping(_ names: [String], from flags: [String]) -> [String] {
        var out: [String] = []
        var skipValue = false
        for flag in flags {
            if skipValue { skipValue = false; if !flag.hasPrefix("-") { continue } }
            if names.contains(flag) { skipValue = true; continue }
            if names.contains(where: { flag.hasPrefix($0 + "=") }) { continue }
            out.append(flag)
        }
        return out
    }

    /// Model router: restart the agent on `tier`, resuming the conversation. With `prompt`, hand it that message
    /// as it starts; without, what's typed in the input box is typed back as after any restart.
    func reroute(to tier: Tier?, sending prompt: String?, note: String?) {
        self.tier = tier
        routeNote = note
        rerouteWhenIdle = false
        if let prompt {
            firstPrompt = prompt
            draft = nil
            pendingDraft = nil
            lastActive = Date()
        } else {
            stashDraft()
        }
        terminate()
        terminal.getTerminal().resetToInitialState()
        start()
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
        if isClaude, claudePid != nil, status == .idle || status == .working, let text = DraftReader.read(terminal.getTerminal()) {
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

    private static func environment(_ extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
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

    /// Auto-allow for this tab alone: nil follows the setting. Stored as the file the ask-on-deny mod reads.
    var autoAllowOverride: Bool? {
        get {
            guard let text = try? String(contentsOf: autoAllowFile, encoding: .utf8) else { return nil }
            return text.hasPrefix("on") ? true : text.hasPrefix("off") ? false : nil
        }
        set {
            objectWillChange.send()
            if let newValue, newValue != DeckSettings.autoAllow {
                try? FileManager.default.createDirectory(at: DeckSettings.autoAllowDir, withIntermediateDirectories: true)
                try? (newValue ? "on" : "off").write(to: autoAllowFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: autoAllowFile) // same as the setting: follow it again
            }
        }
    }

    var autoAllow: Bool { autoAllowOverride ?? DeckSettings.autoAllow }

    private var autoAllowFile: URL { DeckSettings.autoAllowDir.appendingPathComponent(id.uuidString) }

    /// What the ask-on-deny mod let through in this tab, newest first.
    var autoAllowedLog: [(at: Date?, what: String)] {
        let url = DeckSettings.autoAllowDir.appendingPathComponent(id.uuidString + ".log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return text.split(separator: "\n").reversed().map { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 ? (iso.date(from: String(parts[0])), String(parts[1])) : (nil, String(line))
        }
    }

    /// The window title as the agent set it (Codex shows its working spinner there).
    var rawTitle: String?

    fileprivate func titleChanged(_ raw: String) {
        rawTitle = raw
        // Claude prefixes the title with a spinner / ✳ glyph; keep only the words.
        var trimmed = raw.drop { !($0.isLetter || $0.isNumber) }
        // Codex: "<conversation> | <folder>" (just the folder before it has a name).
        if agent == .codex, let bar = trimmed.range(of: " | ", options: .backwards) { trimmed = trimmed[..<bar.lowerBound] }
        if trimmed == folderName { trimmed = "" }
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
