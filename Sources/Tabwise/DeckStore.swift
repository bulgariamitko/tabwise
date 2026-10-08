import AppKit
import SwiftUI
import Combine
import UserNotifications

@MainActor
final class DeckStore: ObservableObject {
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedID: UUID? {
        didSet {
            // Selecting the tab that's in the other pane swaps the panes instead of collapsing the split.
            if splitID != nil, selectedID == splitID, oldValue != nil, oldValue != selectedID { splitID = oldValue }
            selectionChanged()
        }
    }
    /// Tab shown next to the selected one (split view), if any.
    @Published var splitID: UUID? {
        didSet {
            UserDefaults.standard.set(splitID?.uuidString, forKey: "splitTab")
            tabs.first { $0.id == splitID }?.startIfNeeded()
            ActiveSession.publish(self)
        }
    }
    @Published var splitVertical = UserDefaults.standard.object(forKey: "splitVertical") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitVertical, forKey: "splitVertical") }
    }

    /// ⌘D: split with the next tab in the sidebar; again to close.
    func toggleSplit() {
        if splitID != nil { splitID = nil; return }
        let list = ordered
        guard let i = list.firstIndex(where: { $0.id == selectedID }), list.count > 1 else { NSSound.beep(); return }
        splitID = list[(i + 1) % list.count].id
    }
    @Published var showImport = false
    @Published var showResume = false

    enum SidebarMode: String { case open, history }
    @Published var sidebarMode: SidebarMode = .open {
        didSet { if sidebarMode == .history { history.refresh() } }
    }
    @Published var selectedHistoryID: String?
    let history = HistoryStore()
    let prompts = PromptLibrary()
    let folderColors = FolderColors()
    let backup = BackupManager()
    private var backupWatch: Any?
    private var colorsWatch: Any?
    @Published var showSwitcher = false
    /// Set by ⌘E / ⇧⌘N; the sidebar opens its rename / note dialog for this tab.
    @Published var renameRequest: SessionTab?
    @Published var noteRequest: SessionTab?
    @Published var showBroadcast = false
    @Published var showWelcome = false
    /// Closed tabs, newest first, so an accidental ⌘W is never a lost session.
    @Published private(set) var recentlyClosed: [SavedTab] = []

    private let transcripts = TranscriptReader()
    private var pollTimer: Timer?
    private var tick = 0
    private let keepAwake = KeepAwake()
    @Published private(set) var keepingAwake = false
    private var monitorsBusy = false
    /// Transcript reads run here, never on the main thread (some transcripts are 100+ MB).
    private let transcriptQueue = DispatchQueue(label: "tabwise.transcripts", qos: .utility)
    private var transcriptsBusy = false
    /// Called after every status poll (drives the menu bar icon).
    var onPolled: (() -> Void)?
    private var shuttingDown = false
    private var saveScheduled = false

    static let stateURL: URL = {
        // TABWISE_STATE_DIR lets a test copy run without touching your real tabs.
        let dir = ProcessInfo.processInfo.environment["TABWISE_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tabwise")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabs.json")
    }()
    static var backupURL: URL { stateURL.deletingLastPathComponent().appendingPathComponent("tabs.backup.json") }
    static var closedURL: URL { stateURL.deletingLastPathComponent().appendingPathComponent("closed.json") }
    private var lastWritten: Data?

    var selected: SessionTab? { tabs.first { $0.id == selectedID } }

    enum Layout: String { case recent, projects }

    /// Folder groups you've collapsed (Group by Folder layout).
    @Published private(set) var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? [])

    func groupExpanded(_ key: String) -> Binding<Bool> {
        Binding(get: { [weak self] in !(self?.collapsedGroups.contains(key) ?? false) },
                set: { [weak self] open in
                    guard let self else { return }
                    if open { self.collapsedGroups.remove(key) } else { self.collapsedGroups.insert(key) }
                    UserDefaults.standard.set(Array(self.collapsedGroups), forKey: "collapsedGroups")
                })
    }

    @Published var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "sidebarLayout") ?? "") ?? .recent {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "sidebarLayout") }
    }

    /// Sidebar shows only active sessions (green dot); hides asleep, exited and plain shell tabs.
    @Published var activeOnly = UserDefaults.standard.bool(forKey: "sidebarActiveOnly") {
        didSet { UserDefaults.standard.set(activeOnly, forKey: "sidebarActiveOnly") }
    }

    private func shown(_ tab: SessionTab) -> Bool { !activeOnly || tab.status.isActive || tab.id == selectedID }

    // MARK: Search (one box, the same in Open and All Sessions)

    @Published var search = ""
    /// ⌘F: bumped to put the cursor in the sidebar's search box.
    @Published var searchFocusRequest = 0
    @Published var deepSearch = UserDefaults.standard.bool(forKey: "historyDeepSearch") {
        didSet { UserDefaults.standard.set(deepSearch, forKey: "historyDeepSearch") }
    }
    /// Session id → snippet, for conversations whose full text matches (when deepSearch is on).
    @Published private(set) var deepResults: [String: String] = [:]
    @Published private(set) var deepSearching = false

    var searchQuery: String { search.trimmingCharacters(in: .whitespaces).lowercased() }
    var isSearching: Bool { !searchQuery.isEmpty }

    /// The full-text snippet to show for a session, while a deep search is on.
    func searchHit(_ sessionId: String?) -> String? {
        guard isSearching, deepSearch, let sessionId else { return nil }
        return deepResults[sessionId]
    }

    func matches(_ item: HistoryItem) -> Bool {
        let q = searchQuery
        guard !q.isEmpty else { return true }
        return item.id.hasPrefix(q) || searchHit(item.id) != nil
            || historyName(item).lowercased().contains(q)
            || (item.cwd ?? "").lowercased().contains(q)
            || (item.firstPrompt ?? "").lowercased().contains(q)
            || (item.lastPrompt ?? "").lowercased().contains(q)
            || (history.note(item.id) ?? "").lowercased().contains(q)
    }

    func matches(_ tab: SessionTab, items: [String: HistoryItem]) -> Bool {
        let q = searchQuery
        guard !q.isEmpty else { return true }
        if tab.displayName.lowercased().contains(q) || tab.cwd.lowercased().contains(q)
            || (tab.group ?? "").lowercased().contains(q) { return true }
        guard let id = tab.sessionId else { return false }
        if let item = items[id] { return matches(item) }
        return id.hasPrefix(q) || searchHit(id) != nil || (history.note(id) ?? "").lowercased().contains(q)
    }

    /// Full-text search over every conversation, debounced; cancelled when the query changes.
    func runDeepSearch() async {
        let q = searchQuery
        guard deepSearch, q.count >= 3 else { deepResults = [:]; deepSearching = false; return }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        deepSearching = true
        let showEmpty = UserDefaults.standard.bool(forKey: "historyShowEmpty")
        let open = Set(tabs.compactMap(\.sessionId))
        let files = history.items
            .filter { showEmpty || !$0.isTrivial || history.isPinned($0.id) || open.contains($0.id) }
            .map { ($0.id, $0.path) }
        let found = await Task.detached(priority: .userInitiated) { FullTextSearch.search(q, in: files) }.value
        if Task.isCancelled { return }
        deepResults = found
        deepSearching = false
    }

    /// Pinned tabs, in the order you dragged them.
    var pinnedTabs: [SessionTab] { tabs.filter { $0.pinned && !$0.archived && shown($0) } }

    /// Everything else that isn't archived, the session you last messaged first.
    var recentTabs: [SessionTab] {
        tabs.filter { !$0.pinned && !$0.archived && shown($0) }.sorted { $0.lastActive > $1.lastActive }
    }

    /// Recent tabs grouped by project; the group you worked in most recently comes first.
    var projectGroups: [(key: String, tabs: [SessionTab])] {
        var order: [String] = []
        var byKey: [String: [SessionTab]] = [:]
        for tab in recentTabs {
            if byKey[tab.groupKey] == nil { order.append(tab.groupKey) }
            byKey[tab.groupKey, default: []].append(tab)
        }
        return order.map { ($0, byKey[$0]!) }
    }

    var archivedTabs: [SessionTab] { tabs.filter(\.archived).sorted { $0.lastActive > $1.lastActive } }

    /// Tabs whose terminals are alive.
    var liveTabs: [SessionTab] { tabs.filter { !$0.archived } }

    /// Sidebar order of everything that isn't archived (what ⌘1…⌘9 and next/previous follow).
    var ordered: [SessionTab] {
        pinnedTabs + (layout == .projects ? projectGroups.flatMap(\.tabs) : recentTabs)
    }

    var knownGroups: [String] {
        var seen = Set<String>()
        return liveTabs.map(\.groupKey).filter { seen.insert($0).inserted }
    }

    // MARK: Launch

    func launch() {
        let restored = load()
        if let data = try? Data(contentsOf: Self.closedURL),
           let closed = try? Self.decoder.decode([SavedTab].self, from: data) {
            recentlyClosed = closed
        }
        if restored.isEmpty {
            // First launch: welcome screen (checks for Claude Code, offers import); later: import if any.
            if !UserDefaults.standard.bool(forKey: "welcomeShown") {
                UserDefaults.standard.set(true, forKey: "welcomeShown")
                showWelcome = true
            } else if !importCandidates().isEmpty {
                showImport = true
            }
        } else {
            // Background tabs wait until you open them, so launch stays fast;
            // the selected (and split) tab start right away via selection.
            for saved in restored { add(SessionTab(saved: saved), select: false, start: false) }
            selectedID = UserDefaults.standard.string(forKey: "selectedTab").flatMap(UUID.init)
            if selected == nil || selected?.archived == true { selectedID = ordered.first?.id }
            let savedSplit = UserDefaults.standard.string(forKey: "splitTab").flatMap(UUID.init)
            if let savedSplit, liveTabs.contains(where: { $0.id == savedSplit }), savedSplit != selectedID { splitID = savedSplit }
            if DeckSettings.restartRunning {
                // Start the rest of what was running at quit, a few at a time so launch stays smooth.
                for (i, tab) in ordered.filter(\.wasRunning).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.7) { tab.startIfNeeded() }
                }
            }
        }
        if ProcessInfo.processInfo.environment["TABWISE_START_MODE"] == "history" { sidebarMode = .history }
        history.onRefreshed = { [weak self] items in self?.prompts.seedIfNeeded(from: items) }
        colorsWatch = folderColors.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        backupWatch = backup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        history.refresh() // background; also keeps ⌘K and names current
        if ProcessInfo.processInfo.environment["TABWISE_TEST_SLEEP_WAKE"] != nil { // test hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in if let t = self?.selected { self?.sleep(t) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in if let t = self?.selected { self?.wake(t) } }
        }
        if ProcessInfo.processInfo.environment["TABWISE_TEST_BACKUP"] != nil { // test hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.backupConversationsNow() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Tabs

    func newClaude(in cwd: String, resume sessionId: String? = nil, args: [String] = []) {
        let tab = SessionTab(isClaude: true, sessionId: sessionId, cwd: cwd, customName: nil, group: nil)
        tab.extraArgs = args
        if let id = sessionId { tab.customName = history.name(id) }
        add(tab, select: true)
    }

    /// Resume (or start) from a pasted `claude …` command or a bare session ID.
    /// If the session is already a tab, jump to it; if it runs in another window, optionally quit it there first.
    func resume(_ cmd: ResumeCommand, cwd: String, quitOriginal: Bool) {
        if let id = cmd.sessionId, let existing = tabs.first(where: { $0.sessionId == id }) {
            if existing.archived {
                existing.extraArgs = cmd.args
                unarchive(existing)
            } else {
                selectedID = existing.id
            }
            return
        }
        if let id = cmd.sessionId, quitOriginal, let other = Registry.running().first(where: { $0.sessionId == id }) {
            let tty = Registry.tty(of: other.pid)
            kill(other.pid, SIGTERM)
            waitForExit(other.pid, attempts: 30) { [weak self] in
                self?.newClaude(in: cwd, resume: id, args: cmd.args)
                if let tty { Self.closeTerminalWindow(tty: tty) }
            }
            return
        }
        newClaude(in: cwd, resume: cmd.sessionId, args: cmd.args)
    }

    func newShell(in cwd: String) {
        add(SessionTab(isClaude: false, sessionId: nil, cwd: cwd), select: true)
    }

    private func add(_ tab: SessionTab, select: Bool, start: Bool = true) {
        tabs.append(tab)
        if !tab.archived {
            if start { tab.start() } else { tab.status = .notStarted }
        }
        if select { selectedID = tab.id }
        scheduleSave()
    }

    func close(_ tab: SessionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let next = neighbor(of: tab)
        tab.stashDraft() // so Reopen Closed Tab brings it back
        var record = tab.saved
        record.closedAt = Date()
        recentlyClosed.removeAll { $0.id == tab.id || ($0.sessionId != nil && $0.sessionId == tab.sessionId) }
        recentlyClosed.insert(record, at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(30))
        saveClosed()
        tab.terminate()
        tabs.remove(at: index)
        if splitID == tab.id { splitID = nil }
        if selectedID == tab.id { selectedID = next?.id }
        scheduleSave()
    }

    /// The tab to select when `tab` leaves the list: the one below it, else the one above.
    private func neighbor(of tab: SessionTab) -> SessionTab? {
        let list = ordered
        guard let i = list.firstIndex(where: { $0.id == tab.id }) else { return list.first }
        return list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
    }

    // MARK: Pin, color, archive

    func togglePin(_ tab: SessionTab) {
        tab.pinned.toggle()
        if tab.pinned, let i = tabs.firstIndex(where: { $0.id == tab.id }) {
            // Newly pinned tabs go to the bottom of the pinned list.
            tabs.remove(at: i)
            tabs.append(tab)
        }
        objectWillChange.send()
        scheduleSave()
    }

    func setColor(_ tab: SessionTab, _ color: TabColor?) {
        tab.color = color
        objectWillChange.send()
        scheduleSave()
    }

    /// Stops the session to free memory and tucks it into the Archived section.
    /// Put a tab to sleep: its Claude process stops (freeing memory) but the tab and conversation stay.
    func sleep(_ tab: SessionTab) {
        tab.sleep()
        if splitID == tab.id { splitID = nil }
        updateBadge()
        objectWillChange.send()
    }

    /// Everything except the tab you're on (and the one beside it in split view).
    func sleepOthers() {
        for tab in liveTabs where tab.id != selectedID && tab.id != splitID && tab.status != .notStarted { tab.sleep() }
        updateBadge()
        objectWillChange.send()
    }

    func wake(_ tab: SessionTab) {
        tab.startIfNeeded()
        objectWillChange.send()
    }

    func archive(_ tab: SessionTab) {
        guard !tab.archived else { return }
        let next = neighbor(of: tab)
        tab.stashDraft()
        tab.terminate()
        tab.archived = true
        tab.status = .archived
        tab.needsAttention = false
        if splitID == tab.id { splitID = nil }
        if selectedID == tab.id { selectedID = next?.id }
        objectWillChange.send()
        updateBadge()
        scheduleSave()
    }

    /// Brings it back and resumes the conversation.
    func unarchive(_ tab: SessionTab) {
        guard tab.archived else { return }
        tab.archived = false
        tab.restart()
        selectedID = tab.id
        objectWillChange.send()
        scheduleSave()
    }

    func reopenClosed(_ id: UUID? = nil) {
        guard let index = id.map({ id in recentlyClosed.firstIndex { $0.id == id } }) ?? (recentlyClosed.isEmpty ? nil : 0)
        else { return }
        let record = recentlyClosed.remove(at: index)
        saveClosed()
        if let running = tabs.first(where: { $0.sessionId != nil && $0.sessionId == record.sessionId }) {
            selectedID = running.id
            return
        }
        let tab = SessionTab(saved: record)
        tab.archived = false
        tab.status = tab.isClaude ? .starting : .shell
        add(tab, select: true)
    }

    private func saveClosed() {
        if let data = try? Self.encoder.encode(recentlyClosed) { try? data.write(to: Self.closedURL, options: .atomic) }
    }

    /// Name for a past session: what you called it here (All Sessions, an open or closed tab), else /rename or
    /// Claude's title, else your first message.
    func historyName(_ item: HistoryItem) -> String {
        history.name(item.id)
            ?? tabs.first { $0.sessionId == item.id }?.customName
            ?? recentlyClosed.first { $0.sessionId == item.id }?.customName
            ?? item.title
            ?? item.firstPrompt
            ?? String(item.id.prefix(8))
    }

    /// Fresh Claude session in `cwd` (keeping flags like --permission-mode from the tab it came from).
    func newSession(inFolderOf cwd: String?, args: [String] = []) {
        guard let cwd, FileManager.default.fileExists(atPath: cwd) else { NSSound.beep(); return }
        sidebarMode = .open
        newClaude(in: cwd, args: args)
    }

    /// Like `claude --continue`: reopen the most recent conversation in `cwd` (or jump to it if it's already a tab);
    /// starts a new session if that folder has none yet.
    func continueLast(in cwd: String, args: [String] = []) {
        guard FileManager.default.fileExists(atPath: cwd) else { NSSound.beep(); return }
        sidebarMode = .open
        guard let last = HistoryScanner.lastSession(in: cwd) else { newClaude(in: cwd, args: args); return }
        resume(ResumeCommand(sessionId: last.id, args: args), cwd: cwd, quitOriginal: true)
    }

    func openTab(for sessionId: String) -> SessionTab? { tabs.first { $0.sessionId == sessionId } }

    /// Resume a past session as a tab (or jump to it if it's already open) and switch back to Open.
    func resumeHistory(_ item: HistoryItem) {
        guard let cwd = item.cwd, FileManager.default.fileExists(atPath: cwd) else { NSSound.beep(); return }
        sidebarMode = .open
        resume(ResumeCommand(sessionId: item.id), cwd: cwd, quitOriginal: true)
    }

    func rename(_ tab: SessionTab, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        tab.customName = trimmed.isEmpty ? nil : trimmed
        // Remember the name by session, so it survives closing the tab and shows in All Sessions.
        if let id = tab.sessionId { history.setName(id, tab.customName) }
        scheduleSave()
    }

    func setGroup(_ tab: SessionTab, _ group: String?) {
        let trimmed = group?.trimmingCharacters(in: .whitespaces)
        tab.group = (trimmed?.isEmpty ?? true) ? nil : trimmed
        objectWillChange.send()
        scheduleSave()
    }

    /// Drag-reorder inside the Pinned section (the other sections sort themselves by recency).
    func movePinned(from offsets: IndexSet, to destination: Int) {
        var pinned = tabs.filter { $0.pinned && !$0.archived }
        pinned.move(fromOffsets: offsets, toOffset: destination)
        tabs = pinned + tabs.filter { !($0.pinned && !$0.archived) }
        scheduleSave()
    }

    func selectIndex(_ i: Int) {
        let ordered = self.ordered
        guard ordered.indices.contains(i) else { return }
        selectedID = ordered[i].id
    }

    func selectRelative(_ delta: Int) {
        let ordered = self.ordered
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedID } ?? 0
        selectedID = ordered[(current + delta + ordered.count) % ordered.count].id
    }

    private func selectionChanged() {
        selected?.startIfNeeded()
        // Jumping to a tab (⌘1…9, ⌘J, ⌘K) inside a collapsed folder group opens that group.
        if layout == .projects, let key = selected?.groupKey, collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
            UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedGroups")
        }
        selected?.needsAttention = false
        updateBadge()
        UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedTab")
        ActiveSession.publish(self)
    }

    /// ⌘J: the session that's been waiting for you the longest.
    func jumpToNeedsYou() {
        let waiting = liveTabs.filter { $0.id != selectedID && ($0.needsAttention || $0.status == .waiting) }
            .sorted { ($0.attentionSince ?? $0.lastActive) < ($1.attentionSince ?? $1.lastActive) }
        guard let next = waiting.first else { NSSound.beep(); return }
        sidebarMode = .open
        selectedID = next.id
    }

    func appBecameActive() {
        selected?.needsAttention = false
        updateBadge()
    }

    // MARK: Import

    /// Claude sessions running elsewhere (Terminal, iTerm, …) that aren't in this app yet.
    func importCandidates() -> [RegistryEntry] {
        let ours = Set(tabs.compactMap(\.sessionId))
        let ourShells = tabs.map(\.shellPid).filter { $0 > 0 }
        let myPid = getpid()
        return Registry.running()
            .filter { entry in
                !ours.contains(entry.sessionId)
                    && !ourShells.contains { Registry.pid(entry.pid, descendsFrom: $0) }
                    && !Registry.pid(entry.pid, descendsFrom: myPid)
            }
            .sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
    }

    /// Sessions from the last claude-sessions snapshot that aren't running anywhere now.
    func snapshotCandidates() -> [SnapshotEntry] {
        let running = Set(Registry.running().map(\.sessionId))
        let ours = Set(tabs.compactMap(\.sessionId))
        return Registry.snapshot().filter { !running.contains($0.sessionId) && !ours.contains($0.sessionId) }
    }

    /// Reopen external sessions here with `claude --resume`. Optionally quit the originals first so the
    /// same conversation isn't driven from two places, and close their Terminal.app windows.
    func importSessions(_ entries: [RegistryEntry], snapshots: [SnapshotEntry], closeOriginals: Bool) {
        for s in snapshots { newClaude(in: s.cwd, resume: s.sessionId) }
        for entry in entries {
            guard closeOriginals else {
                newClaude(in: entry.cwd, resume: entry.sessionId)
                continue
            }
            let tty = Registry.tty(of: entry.pid)
            kill(entry.pid, SIGTERM)
            waitForExit(entry.pid, attempts: 30) { [weak self] in
                self?.newClaude(in: entry.cwd, resume: entry.sessionId)
                if let tty { Self.closeTerminalWindow(tty: tty) }
            }
        }
    }

    private func waitForExit(_ pid: Int32, attempts: Int, then: @escaping @MainActor () -> Void) {
        if !Registry.isAlive(pid) || attempts == 0 {
            if attempts == 0 { kill(pid, SIGKILL) }
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.waitForExit(pid, attempts: attempts - 1, then: then) }
        }
    }

    private static func closeTerminalWindow(tty: String) {
        let script = """
        if application "Terminal" is running then
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "\(tty)" then
                  close w saving no
                  return
                end if
              end repeat
            end repeat
          end tell
        end if
        """
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    // MARK: Status polling

    private func poll() {
        let entries = Registry.running()
        let appActive = NSApp.isActive
        var statusChanged = false
        refreshTranscripts()
        for tab in tabs {
            let previous = tab.status
            if tab.status == .exited || tab.status == .notStarted || tab.archived { continue }
            let match = tab.shellPid > 0
                ? entries.first { Registry.pid($0.pid, descendsFrom: tab.shellPid) }
                : nil
            tab.claudePid = match?.pid
            if let match {
                if tab.sessionId != match.sessionId { tab.sessionId = match.sessionId; scheduleSave() }
                tab.registryName = match.name
                if match.cwd != tab.cwd { tab.cwd = match.cwd }
                tab.status = Self.status(from: match.status)
            } else if tab.status != .starting || Date().timeIntervalSince(tab.startedAt) > 20 {
                tab.status = .shell
            }


            if tab.status != previous { statusChanged = true }
            let finished = previous == .working && (tab.status == .idle || tab.status == .waiting)
            let nowWaiting = previous != .waiting && tab.status == .waiting
            if finished || nowWaiting, !(appActive && tab.id == selectedID) {
                if !tab.needsAttention { tab.attentionSince = Date() }
                tab.needsAttention = true
                notify(tab, waiting: tab.status == .waiting)
                updateBadge()
            }
        }
        if statusChanged { objectWillChange.send() } // also refreshes group headers and counts
        let awake: Bool
        switch DeckSettings.keepAwake {
        case .working: awake = liveTabs.contains { $0.status == .working }
        case .open: awake = liveTabs.contains { $0.claudePid != nil }
        case .never: awake = false
        }
        keepAwake.set(awake, reason: "Tabwise: Claude sessions are running")
        if keepingAwake != keepAwake.active { keepingAwake = keepAwake.active }
        if Demo.tabs != nil { Demo.apply(to: tabs); objectWillChange.send() } // README screenshots only
        tick += 1
        if tick % 5 == 1 { refreshMonitors(git: tick % 15 == 1) }
        if tick % 60 == 30 { autoArchiveIdle() }
        if tick % 2 == 0 { scanDrafts() }
        if tick % 60 == 45 { backup.backupAppData(tabCount: tabs.count) }
        if tick % 3600 == 120 { backupConversationsNow() } // hourly (first run 2 min after launch)
        onPolled?()
        ActiveSession.publish(self) // picks up new session ids (resume, /clear) and closed tabs
        // Cheap: only touches the disk when something actually changed.
        save()
    }

    /// Titles, previews and last-message times from each tab's transcript, read off the main thread.
    private func refreshTranscripts() {
        guard !transcriptsBusy else { return }
        let jobs = tabs.compactMap { tab in tab.sessionId.map { (tab: tab.id, session: $0, cwd: tab.cwd) } }
        guard !jobs.isEmpty else { return }
        transcriptsBusy = true
        let reader = transcripts
        transcriptQueue.async {
            let results = jobs.compactMap { job in
                reader.read(sessionId: job.session, cwd: job.cwd).map { (tab: job.tab, session: job.session, info: $0) }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.transcriptsBusy = false
                    var resort = false
                    for result in results {
                        guard let tab = self.tabs.first(where: { $0.id == result.tab }),
                              tab.sessionId == result.session, result.info != tab.transcript else { continue }
                        tab.transcript = result.info
                        if let at = result.info.lastUserAt, at > tab.lastActive {
                            tab.lastActive = at
                            resort = true
                        }
                    }
                    // The sidebar sorts on the store, so tell it when a tab's last-message time moved.
                    if resort { self.objectWillChange.send() }
                }
            }
        }
    }

    /// Memory per session (every 5 s) and git state per folder (every 15 s), measured off the main thread.
    private func refreshMonitors(git: Bool) {
        guard !monitorsBusy, Demo.tabs == nil else { return }
        monitorsBusy = true
        let live = liveTabs
        let pids = live.map { ($0.id, $0.claudePid ?? $0.shellPid) }
        let folders = git ? Array(Set(live.map(\.cwd))) : []
        DispatchQueue.global(qos: .utility).async {
            let memory = Dictionary(pids.map { ($0.0, $0.1 > 0 ? ProcessMemory.footprint(ofTree: $0.1) : 0) },
                                    uniquingKeysWith: { a, _ in a })
            var gitInfo: [String: GitInfo?] = [:]
            for folder in folders { gitInfo[folder] = GitInfo.read(folder) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.monitorsBusy = false
                    var changed = false
                    for tab in self.tabs {
                        if let m = memory[tab.id], m != tab.memory { tab.memory = m; changed = true }
                        if let g = gitInfo[tab.cwd], g != tab.git { tab.git = g }
                    }
                    if changed { self.objectWillChange.send() } // footer total
                }
            }
        }
    }

    private static let debugDrafts = ProcessInfo.processInfo.environment["TABWISE_DEBUG_DRAFTS"] != nil
    private static var testTyped = false

    /// Save what's typed in each Claude input box; after a restart, type the saved draft back in.
    private func scanDrafts() {
        for tab in liveTabs where tab.claudePid != nil && (tab.status == .idle || tab.status == .working) {
            let t = tab.terminal.getTerminal()
            guard let text = DraftReader.read(t) else { continue }
            if Self.debugDrafts {
                let dump = DraftReader.dump(t) + "\n=== parsed: [\(text)]\n"
                try? dump.write(to: Self.stateURL.deletingLastPathComponent().appendingPathComponent("draft-debug.txt"),
                                atomically: true, encoding: .utf8)
                if !Self.testTyped, let typed = ProcessInfo.processInfo.environment["TABWISE_TEST_TYPE"],
                   tab.status == .idle, Date().timeIntervalSince(tab.startedAt) > 6 {
                    Self.testTyped = true
                    tab.terminal.insert(typed.replacingOccurrences(of: "\\n", with: "\n"), submit: false)
                }
            }
            if let pending = tab.pendingDraft {
                // Wait until Claude has settled, then type it into the empty box. A big conversation can still be
                // loading and drop the text, so keep it (and the Draft badge) until it actually shows up, retrying.
                guard tab.status == .idle, Date().timeIntervalSince(tab.startedAt) > 4 else { continue }
                if !text.isEmpty || tab.draftRestoreTries >= 10 {
                    tab.pendingDraft = nil // it's in the box (or you typed something else there)
                } else {
                    if Date().timeIntervalSince(tab.lastDraftRestore) > 4 {
                        tab.draftRestoreTries += 1
                        tab.lastDraftRestore = Date()
                        tab.terminal.insert(pending.replacingOccurrences(of: "\u{0}", with: " "), submit: false)
                    }
                    continue
                }
            }
            let draft = text.isEmpty ? nil : text
            if draft != tab.draft { tab.draft = draft }
        }
    }

    var totalMemory: UInt64 { liveTabs.reduce(0) { $0 + $1.memory } }

    /// Settings → Auto-archive: stop idle, unpinned sessions you haven't messaged in N days.
    private func autoArchiveIdle() {
        let days = DeckSettings.autoArchiveDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for tab in liveTabs where tab.isClaude && !tab.pinned && tab.id != selectedID
            && tab.status == .idle && tab.lastActive > .distantPast && tab.lastActive < cutoff {
            archive(tab)
        }
    }

    private static func status(from raw: String?) -> TabStatus {
        switch raw {
        case "busy": .working
        case let s? where s.hasPrefix("waiting"): .waiting
        default: .idle
        }
    }

    private func notify(_ tab: SessionTab, waiting: Bool) {
        let content = UNMutableNotificationContent()
        content.title = tab.displayName
        content.subtitle = waiting ? "Needs your input" : "Finished"
        content.body = tab.transcript.preview ?? tab.shortPath
        content.sound = .default
        content.userInfo = ["tab": tab.id.uuidString]
        let request = UNNotificationRequest(identifier: tab.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func updateBadge() {
        let count = tabs.filter(\.needsAttention).count
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: Persistence

    func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.save()
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func save() {
        guard !shuttingDown else { return } // keep the "was running" flags written at quit
        let records = tabs.map { tab -> SavedTab in var r = tab.saved; r.title = nil; return r }
        guard let data = try? Self.encoder.encode(records), data != lastWritten else { return }
        let fm = FileManager.default
        // Keep the previous non-empty state around in case the main file is ever damaged.
        if let previous = try? Data(contentsOf: Self.stateURL),
           let old = try? Self.decoder.decode([SavedTab].self, from: previous), !old.isEmpty {
            try? fm.removeItem(at: Self.backupURL)
            try? previous.write(to: Self.backupURL, options: .atomic)
        }
        if (try? data.write(to: Self.stateURL, options: .atomic)) != nil { lastWritten = data }
    }

    private func load() -> [SavedTab] {
        for url in [Self.stateURL, Self.backupURL] {
            if let data = try? Data(contentsOf: url), let saved = try? Self.decoder.decode([SavedTab].self, from: data) {
                if url == Self.stateURL { lastWritten = data }
                return saved
            }
        }
        return []
    }

    func applyFont() {
        for tab in tabs { Theme.apply(to: tab.terminal) }
        UserDefaults.standard.set(Theme.fontSize, forKey: "fontSize")
    }

    /// Your real conversations (not one-message automated runs), plus anything pinned or open.
    func backupConversationsNow() {
        let open = Set(tabs.compactMap(\.sessionId))
        let ids = Set(history.items.filter { !$0.isTrivial || history.isPinned($0.id) || open.contains($0.id) }.map(\.id))
        backup.backupAppData(tabCount: tabs.count)
        backup.backupConversations(sessionIds: ids, items: history.items, tabCount: tabs.count)
    }

    func shutdown() {
        ActiveSession.publish(self, quitting: true)
        save()
        shuttingDown = true
        backup.backupAppData(tabCount: tabs.count)
        for tab in tabs { tab.terminate() }
    }
}
