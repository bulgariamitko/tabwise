import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: DeckStore

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 460)
        } detail: {
            ZStack {
                Color(nsColor: Theme.background).ignoresSafeArea()
                TerminalHost(tabs: store.liveTabs, selectedID: store.selectedID,
                             splitID: store.splitID, vertical: store.splitVertical)
                    .padding(.leading, 6)
                    .padding(.top, 2)
                if store.sidebarMode == .history {
                    HistoryDetail(store: store, history: store.history)
                } else if let tab = store.selected, tab.archived {
                    ArchivedPlaceholder(tab: tab, store: store)
                } else if let tab = store.selected, tab.status == .notStarted {
                    SleepingPlaceholder(tab: tab, store: store)
                } else if store.liveTabs.isEmpty {
                    EmptyState(store: store)
                }
            }
            .navigationTitle(store.sidebarMode == .history ? "All Sessions" : store.selected?.displayName ?? "Tabwise")
            .navigationSubtitle(store.sidebarMode == .history ? "" : store.selected?.shortPath ?? "")
        }
        .sheet(isPresented: $store.showImport) {
            ImportSheet(store: store)
        }
        .sheet(isPresented: $store.showResume) {
            ResumeSheet(store: store)
        }
        .sheet(isPresented: $store.showWelcome) {
            WelcomeView(store: store)
        }
        .sheet(isPresented: $store.showSwitcher) {
            QuickSwitcher(store: store, history: store.history)
        }
        .sheet(isPresented: $store.showBroadcast) {
            BroadcastSheet(store: store, prompts: store.prompts)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var store: DeckStore
    @State private var renaming: SessionTab?
    @State private var renameText = ""
    @State private var regrouping: SessionTab?
    @State private var groupText = ""
    @State private var dropTargeted = false
    @AppStorage("archiveExpanded") private var archiveExpanded = false
    @AppStorage("pinnedExpanded") private var pinnedExpanded = true
    @State private var notingSession: String?
    @State private var noteText = ""

    var body: some View {
        Group {
            if store.sidebarMode == .open { openList } else { HistoryList(store: store, history: store.history) }
        }
        .task(id: "\(store.deepSearch)|\(store.search)") { await store.runDeepSearch() }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                Picker("", selection: $store.sidebarMode) {
                    Text("Open").tag(DeckStore.SidebarMode.open)
                    Text("All Sessions").tag(DeckStore.SidebarMode.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if store.sidebarMode == .open {
                    HStack(spacing: 8) {
                        StatusSummary(store: store)
                        Spacer(minLength: 4)
                        Button { store.activeOnly.toggle() } label: {
                            Image(systemName: store.activeOnly ? "bolt.circle.fill" : "bolt.circle")
                                .foregroundStyle(store.activeOnly ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(store.activeOnly ? "Showing only active sessions — click to show all" : "Show only active sessions (green dot)")
                        Menu {
                            Toggle("Only Active Sessions", isOn: $store.activeOnly)
                            Divider()
                            Picker("Sidebar", selection: $store.layout) {
                                Text("Most Recent First").tag(DeckStore.Layout.recent)
                                Text("Group by Folder").tag(DeckStore.Layout.projects)
                            }
                            .pickerStyle(.inline)
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Sidebar layout")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var openList: some View {
        let ordered = store.ordered
        // Search: the same box as All Sessions; open tabs that match, then matching sessions that aren't open.
        let searching = store.isSearching
        let items = Dictionary(store.history.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let match = { (tab: SessionTab) in store.matches(tab, items: items) }
        let pinned = store.pinnedTabs.filter(match)
        let recent = store.recentTabs.filter(match)
        let groups = store.projectGroups.map { (key: $0.key, tabs: $0.tabs.filter(match)) }.filter { !$0.tabs.isEmpty }
        let archived = store.archivedTabs.filter(match)
        let notOpen = searching ? store.history.items
            .filter { store.openTab(for: $0.id) == nil && (!$0.isTrivial || store.history.isPinned($0.id)) && store.matches($0) }
            .sorted { $0.lastActive > $1.lastActive } : []
        return List(selection: $store.selectedID) {
            if !pinned.isEmpty {
                Section(isExpanded: searching ? .constant(true) : $pinnedExpanded) {
                    ForEach(pinned) { tab in row(tab, ordered) }
                        .onMove(perform: store.activeOnly || searching ? nil : { store.movePinned(from: $0, to: $1) })
                } header: {
                    SectionHeader(title: "Pinned (\(pinned.count))", icon: "pin.fill", expanded: $pinnedExpanded)
                }
            }
            if store.layout == .projects {
                ForEach(groups, id: \.key) { group in
                    Section(isExpanded: searching ? .constant(true) : store.groupExpanded(group.key)) {
                        ForEach(group.tabs) { tab in row(tab, ordered) }
                    } header: {
                        FolderGroupHeader(store: store, key: group.key, tabs: group.tabs)
                    }
                }
            } else if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { tab in row(tab, ordered) }
                }
            }
            if store.activeOnly {
                let hidden = store.liveTabs.count - ordered.count
                Button(hidden > 0 ? "\(hidden) inactive hidden — Show All" : "Show All") { store.activeOnly = false }
                    .buttonStyle(.link).font(.caption).selectionDisabled()
            } else if !archived.isEmpty {
                Section(isExpanded: searching ? .constant(true) : $archiveExpanded) {
                    ForEach(archived) { tab in row(tab, ordered) }
                } header: {
                    SectionHeader(title: "Archived (\(archived.count))", icon: "archivebox", expanded: $archiveExpanded)
                }
            }
            if !notOpen.isEmpty {
                Section {
                    ForEach(notOpen.prefix(100)) { item in ClosedSessionRow(store: store, item: item) }
                } header: {
                    Label("Not Open (\(notOpen.count))", systemImage: "clock.arrow.circlepath")
                }
            }
            if searching && pinned.isEmpty && recent.isEmpty && groups.isEmpty && archived.isEmpty && notOpen.isEmpty {
                Text(store.deepSearching ? "Searching…" : "No sessions match “\(store.search)”")
                    .font(.callout).foregroundStyle(.secondary).selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 4) { SearchBar(store: store) { EmptyView() } }
        .animation(.default, value: ordered.map(\.id))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .overlay(Text("Drop a folder to start Claude there").font(.callout).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)))
                    .padding(6)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    let dir = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
                    DispatchQueue.main.async { store.newClaude(in: dir) }
                }
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { AppActions.newSession(store) } label: { Label("New", systemImage: "plus") }
                Button { store.showResume = true } label: { Label("Resume", systemImage: "arrow.uturn.forward") }
                Button { store.showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: store.renameRequest?.id) {
            guard let tab = store.renameRequest else { return }
            store.renameRequest = nil
            renameText = tab.customName ?? tab.displayName; renaming = tab
        }
        .onChange(of: store.noteRequest?.id) {
            guard let tab = store.noteRequest else { return }
            store.noteRequest = nil
            guard let id = tab.sessionId else { return }
            noteText = store.history.note(id) ?? ""; notingSession = id
        }
        .alert("Rename tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let t = renaming { store.rename(t, to: renameText) } }
            Button("Use automatic name") { if let t = renaming { store.rename(t, to: "") } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Note", isPresented: Binding(get: { notingSession != nil }, set: { if !$0 { notingSession = nil } })) {
            TextField("e.g. waiting on client reply", text: $noteText)
            Button("Save") { if let id = notingSession { store.history.setNote(id, noteText) } }
            Button("Remove Note") { if let id = notingSession { store.history.setNote(id, nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Move to group", isPresented: Binding(get: { regrouping != nil }, set: { if !$0 { regrouping = nil } })) {
            TextField("Group name", text: $groupText)
            Button("Move") { if let t = regrouping { store.setGroup(t, groupText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ tab: SessionTab, _ ordered: [SessionTab]) -> some View {
        TabRow(tab: tab, index: ordered.firstIndex { $0.id == tab.id }, note: store.history.note(tab.sessionId),
               isSplit: store.splitID == tab.id && store.selectedID != tab.id,
               folderColor: store.folderColors.color(for: tab.cwd), hit: store.searchHit(tab.sessionId))
            .tag(tab.id)
            .contextMenu { menu(for: tab) }
            .listRowBackground(tab.color.map { c in
                RoundedRectangle(cornerRadius: 6).fill(c.swiftUI.opacity(0.13)).padding(.horizontal, 10)
            })
    }

    @ViewBuilder
    private func menu(for tab: SessionTab) -> some View {
        if tab.archived {
            Button("Unarchive and Resume") { store.unarchive(tab) }
            Divider()
        } else {
            Button(tab.pinned ? "Unpin" : "Pin to Top") { store.togglePin(tab) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        FolderColorMenu(colors: store.folderColors, path: tab.cwd)
        Menu("Color") {
            ForEach(TabColor.allCases) { c in
                Button {
                    store.setColor(tab, c)
                } label: {
                    Label(c.name, systemImage: tab.color == c ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(c.swiftUI)
            }
            Divider()
            Button("No Color") { store.setColor(tab, nil) }.disabled(tab.color == nil)
        }
        Button("Rename…") { renameText = tab.customName ?? tab.displayName; renaming = tab }
            .keyboardShortcut("e", modifiers: .command)
        if let id = tab.sessionId {
            Button(store.history.note(id) == nil ? "Add Note…" : "Edit Note…") {
                noteText = store.history.note(id) ?? ""; notingSession = id
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        if !tab.archived, [.idle, .working, .waiting].contains(tab.status), !store.prompts.prompts.isEmpty {
            Menu("Send Prompt") {
                ForEach(store.prompts.prompts) { p in
                    Button(String(p.text.prefix(60))) { tab.terminal.insert(p.text, submit: true) }
                }
            }
        }
        Menu("Move to Group") {
            ForEach(store.knownGroups.filter { $0 != tab.groupKey }, id: \.self) { g in
                Button(g) { store.setGroup(tab, g) }
            }
            Divider()
            Button("New Group…") { groupText = ""; regrouping = tab }
            if tab.group != nil {
                Button("By Folder (\(tab.folderName))") { store.setGroup(tab, nil) }
            }
        }
        Divider()
        Button("Start New Session in This Folder") { store.newSession(inFolderOf: tab.cwd, args: tab.extraArgs) }
            .keyboardShortcut("t", modifiers: [.command, .control])
        Button("Open Shell in This Folder") { store.newShell(in: tab.cwd) }
            .keyboardShortcut("t", modifiers: [.command, .option])
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tab.cwd) }
            .keyboardShortcut("r", modifiers: [.command, .option])
        if let id = tab.sessionId {
            Button("Copy Session ID") { AppActions.copySessionID(tab) }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
        if !tab.archived && tab.id != store.selectedID {
            Button(store.splitID == tab.id ? "Close Split" : "Show Side by Side") {
                store.splitID = store.splitID == tab.id ? nil : tab.id
            }
        }
        if !tab.archived {
            Button(tab.isClaude ? "Restart (resume conversation)" : "Restart") { tab.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(tab.status == .notStarted ? "Wake Up" : "Put to Sleep (free memory)") {
                AppActions.toggleSleep(tab, store: store)
            }
            .keyboardShortcut("s", modifiers: .command)
            Button("Put Other Tabs to Sleep") { store.sleepOthers() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Archive") { store.archive(tab) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        } else {
            Divider()
        }
        Button("Close Tab") { AppActions.close(tab, store: store) }
            .keyboardShortcut("w", modifiers: .command)
    }
}

struct TabRow: View {
    @ObservedObject var tab: SessionTab
    let index: Int?
    var note: String? = nil
    var isSplit = false
    var folderColor: Color = .secondary
    /// Where a full-text search matched this conversation.
    var hit: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let color = tab.color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.swiftUI)
                    .frame(width: 3)
                    .padding(.vertical, 1)
                    .padding(.trailing, -3)
            }
            StatusIndicator(status: tab.status, attention: tab.needsAttention)
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(tab.displayName)
                        .font(.body.weight(tab.needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSplit { Image(systemName: "rectangle.split.2x1").font(.caption).foregroundStyle(.secondary).help("Shown in split view") }
                    if let index, index < 9 {
                        Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let note { NoteLabel(note: note) }
                HStack(spacing: 4) {
                    FolderLabel(text: FolderColors.shortPath(tab.cwd), color: folderColor).help(tab.shortPath)
                    if tab.lastActive > .distantPast {
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(Self.relative(tab.lastActive)).fixedSize()
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                TabMeta(tab: tab)
                if let hit {
                    Text(hit).font(.caption).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                } else if let preview = tab.transcript.preview {
                    Text((tab.transcript.previewIsUser ? "You: " : "") + preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(tab.archived ? 0.6 : 1)
        .help("\(tab.displayName)\n\(tab.status.label) · \(tab.shortPath)")
    }
}

extension TabRow {
    static func relative(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(86400 * 7): return "\(Int(s / 86400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

extension TabColor {
    var swiftUI: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// Shown for the selected tab after you put it to sleep.
struct SleepingPlaceholder: View {
    @ObservedObject var tab: SessionTab
    let store: DeckStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(tab.displayName).font(.title2)
            Text("This session is asleep and uses no memory.\nWake it up to continue the conversation where you left off.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Wake Up") { store.wake(tab) }.keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white)
        .padding(40)
    }
}

struct ArchivedPlaceholder: View {
    @ObservedObject var tab: SessionTab
    let store: DeckStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(tab.displayName).font(.title2)
            Text("This session is archived and not running.\nUnarchive it to resume the conversation where you left off.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Unarchive and Resume") { store.unarchive(tab) }.keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white)
        .padding(40)
    }
}

/// Git branch/changes and memory for a running tab, in one small line.
/// Header of a folder group: colored name, how many sessions, and what's working or waiting —
/// still visible when the group is collapsed.
/// A collapsible section's title; clicking anywhere on it (not just the arrow) expands or collapses it.
struct SectionHeader: View {
    let title: String
    let icon: String
    @Binding var expanded: Bool

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }
}

struct FolderGroupHeader: View {
    @ObservedObject var store: DeckStore
    let key: String
    let tabs: [SessionTab]

    var body: some View {
        let working = tabs.filter { $0.status == .working }.count
        let waiting = tabs.filter { $0.status == .waiting || $0.needsAttention }.count
        let expanded = store.groupExpanded(key)
        HStack(spacing: 6) {
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            FolderLabel(text: key, color: store.folderColors.color(for: tabs.first?.cwd))
                .font(.callout.weight(.semibold))
            Text("\(tabs.count)").font(.caption).foregroundStyle(.tertiary)
            if working > 0 {
                HStack(spacing: 2) {
                    ProgressView().controlSize(.mini)
                    if working > 1 { Text("\(working)").font(.caption2) }
                }
                .help("\(working) working")
            }
            if waiting > 0 {
                Label("\(waiting)", systemImage: "bell.fill").labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(.orange)
                    .help("\(waiting) waiting for you")
            }
            Spacer()
            Button {
                store.newClaude(in: tabs.first?.cwd ?? NSHomeDirectory())
            } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)
            .help("New session in \(key)")
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.wrappedValue.toggle() }
    }
}

struct TabMeta: View {
    @ObservedObject var tab: SessionTab
    var body: some View {
        let showMemory = !tab.archived && tab.memory > 0
        if tab.git != nil || showMemory || tab.draft != nil {
            HStack(spacing: 10) {
                if let draft = tab.draft {
                    Label("Draft", systemImage: "pencil.line")
                        .foregroundStyle(.yellow.opacity(0.9))
                        .help("Unsent text in the input box (kept across restarts):\n\(draft)")
                }
                if let git = tab.git {
                    Label(git.label, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(git.changed > 0 ? Color.orange.opacity(0.85) : Color.secondary)
                        .help(git.changed > 0 ? "\(git.changed) uncommitted change(s) on \(git.branch)" : "Clean on \(git.branch)")
                }
                if showMemory {
                    Label(ProcessMemory.format(tab.memory), systemImage: "memorychip")
                        .foregroundStyle(tab.memory > 2_000_000_000 ? Color.red.opacity(0.8) : Color.secondary)
                        .help("Memory used by this session")
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
    }
}

struct NoteLabel: View {
    let note: String
    var body: some View {
        Label(note, systemImage: "note.text")
            .font(.caption)
            .foregroundStyle(.yellow.opacity(0.85))
            .lineLimit(2)
            .labelStyle(.titleAndIcon)
    }
}

struct StatusIndicator: View {
    let status: TabStatus
    let attention: Bool

    var body: some View {
        switch status {
        case .working, .starting:
            ProgressView().controlSize(.mini).opacity(status == .starting ? 0.5 : 1)
        default:
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: attention ? 4 : 0))
                .overlay(Circle().stroke(Color.gray.opacity(0.7), lineWidth: 1).opacity(status == .notStarted ? 1 : 0))
                .padding(.top, 3)
        }
    }

    private var color: Color {
        switch status {
        case .waiting: .orange
        case .idle: attention ? .blue : .green.opacity(0.75)
        case .shell: .gray.opacity(0.6)
        case .exited: .red.opacity(0.7)
        case .archived: .gray.opacity(0.4)
        case .notStarted: .clear
        default: .gray
        }
    }
}

struct StatusSummary: View {
    @ObservedObject var store: DeckStore
    var body: some View {
        let working = store.liveTabs.filter { $0.status == .working }.count
        let waiting = store.tabs.filter { $0.status == .waiting || $0.needsAttention }.count
        HStack(spacing: 8) {
            if let p = store.backup.restoreProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 50)
                    .help("Restoring conversations from backup: \(p.done) of \(p.total)")
            } else if store.backup.running {
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary).help("Backing up…")
            }
            if store.keepingAwake {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.secondary)
                    .help("Keeping the Mac awake while sessions run (Settings → Power)")
            }
            if store.totalMemory > 0 {
                Text(ProcessMemory.format(store.totalMemory)).foregroundStyle(.tertiary).help("Memory used by all running sessions")
            }
            if working > 0 { Label("\(working)", systemImage: "bolt.fill").foregroundStyle(.secondary) }
            if waiting > 0 { Label("\(waiting)", systemImage: "bell.fill").foregroundStyle(.orange) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
    }
}

struct EmptyState: View {
    @ObservedObject var store: DeckStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No sessions yet").font(.title2)
            Text("Start a new Claude session, import the ones running in Terminal,\nor drop a folder onto the sidebar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("New Session…") { AppActions.newSession(store) }.keyboardShortcut(.defaultAction)
                Button("Import Running Sessions…") { store.showImport = true }
            }
        }
        .foregroundStyle(.white)
        .padding(40)
    }
}

// MARK: Terminal host

/// Keeps every tab's terminal view alive in one container and shows the selected one, or two side by side
/// in split view, so switching tabs never restarts or redraws a session.
struct TerminalHost: NSViewRepresentable {
    let tabs: [SessionTab]
    let selectedID: UUID?
    var splitID: UUID? = nil
    var vertical = true

    final class Coordinator { var lastSelected: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitContainer { SplitContainer() }

    func updateNSView(_ container: SplitContainer, context: Context) {
        let live = Set(tabs.map { ObjectIdentifier($0.terminal) })
        for sub in container.subviews where sub !== container.divider && !live.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperview()
        }
        let primary = tabs.first { $0.id == selectedID }?.terminal
        let secondary = splitID == selectedID ? nil : tabs.first { $0.id == splitID }?.terminal
        for tab in tabs {
            let tv = tab.terminal
            if tv.superview !== container { container.addSubview(tv, positioned: .below, relativeTo: container.divider) }
            tv.isHidden = tv !== primary && tv !== secondary
        }
        container.primary = primary
        container.secondary = secondary
        container.vertical = vertical
        container.needsLayout = true
        if context.coordinator.lastSelected != selectedID {
            context.coordinator.lastSelected = selectedID
            if let primary { DispatchQueue.main.async { primary.window?.makeFirstResponder(primary) } }
        }
    }
}

final class SplitContainer: NSView {
    weak var primary: NSView?
    weak var secondary: NSView?
    var vertical = true
    private var fraction: CGFloat = {
        let f = UserDefaults.standard.double(forKey: "splitFraction")
        return f > 0.15 && f < 0.85 ? f : 0.5
    }()
    let divider = SplitDivider()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        addSubview(divider)
        divider.onDrag = { [weak self] point in self?.dragDivider(to: point) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        guard let primary else { divider.isHidden = true; return }
        guard let secondary else {
            divider.isHidden = true
            primary.frame = b
            return
        }
        divider.isHidden = false
        let gap: CGFloat = 6
        if vertical {
            let w = (b.width - gap) * fraction
            primary.frame = NSRect(x: 0, y: 0, width: w, height: b.height)
            divider.frame = NSRect(x: w, y: 0, width: gap, height: b.height)
            secondary.frame = NSRect(x: w + gap, y: 0, width: b.width - w - gap, height: b.height)
        } else {
            let h = (b.height - gap) * fraction
            primary.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
            divider.frame = NSRect(x: 0, y: b.height - h - gap, width: b.width, height: gap)
            secondary.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - h - gap)
        }
        divider.vertical = vertical
    }

    private func dragDivider(to windowPoint: NSPoint) {
        let p = convert(windowPoint, from: nil)
        let raw = vertical ? p.x / max(bounds.width, 1) : 1 - p.y / max(bounds.height, 1)
        fraction = min(max(raw, 0.15), 0.85)
        UserDefaults.standard.set(fraction, forKey: "splitFraction")
        needsLayout = true
    }
}

final class SplitDivider: NSView {
    var vertical = true { didSet { window?.invalidateCursorRects(for: self) } }
    var onDrag: ((NSPoint) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = vertical ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
                            : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }
}

// MARK: Import

struct ImportSheet: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    @State private var running: [RegistryEntry] = []
    @State private var snapshots: [SnapshotEntry] = []
    @State private var picked = Set<String>()
    @State private var closeOriginals = true
    @State private var titles: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Claude sessions").font(.title2.bold())
            Text("Each one reopens here with `claude --resume`, so the conversation carries over.")
                .foregroundStyle(.secondary)

            List {
                if !running.isEmpty {
                    Section("Running now in other windows") {
                        ForEach(running) { e in
                            row(id: e.sessionId, name: titles[e.sessionId] ?? e.name ?? "session", cwd: e.cwd,
                                badge: e.status == "busy" ? "working" : nil)
                        }
                    }
                }
                if !snapshots.isEmpty {
                    Section("From your last saved snapshot (not running)") {
                        ForEach(snapshots) { s in row(id: s.sessionId, name: titles[s.sessionId] ?? s.name ?? "session", cwd: s.cwd, badge: nil) }
                    }
                }
                if running.isEmpty && snapshots.isEmpty {
                    Text("No other Claude sessions found.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 280)

            Toggle("Quit the originals and close their Terminal windows", isOn: $closeOriginals)
            if closeOriginals && running.contains(where: { picked.contains($0.sessionId) && $0.status == "busy" }) {
                Label("Some selected sessions are working right now; quitting them interrupts the current turn.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }

            HStack {
                Button(picked.count == running.count + snapshots.count ? "Select None" : "Select All") {
                    let all = Set(running.map(\.sessionId) + snapshots.map(\.sessionId))
                    picked = picked == all ? [] : all
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(picked.count)") {
                    store.importSessions(running.filter { picked.contains($0.sessionId) },
                                         snapshots: snapshots.filter { picked.contains($0.sessionId) },
                                         closeOriginals: closeOriginals)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear {
            running = store.importCandidates()
            snapshots = store.snapshotCandidates()
            picked = Set(running.filter { $0.status != "busy" }.map(\.sessionId))
            let reader = TranscriptReader()
            for (id, cwd) in running.map({ ($0.sessionId, $0.cwd) }) + snapshots.map({ ($0.sessionId, $0.cwd) }) {
                titles[id] = reader.read(sessionId: id, cwd: cwd)?.title
            }
        }
    }

    private func row(id: String, name: String, cwd: String, badge: String?) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(id) }, set: { if $0 { picked.insert(id) } else { picked.remove(id) } })) {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                    Text((cwd as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let badge { Text(badge).font(.caption).foregroundStyle(.orange) }
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: Resume

/// Paste `claude --permission-mode auto --resume <id>` (or just the ID) to reopen that conversation here.
struct ResumeSheet: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var matches: [SessionLookup] = []
    @State private var chosen: String?
    @State private var folder: String = AppActions.lastFolder
    @State private var quitOriginal = true
    @State private var searched = false
    @State private var lastInFolder: HistoryItem?

    private var command: ResumeCommand { ResumeCommand.parse(text) }
    private var continuing: Bool { command.sessionId == nil && command.continueLast }
    private var match: SessionLookup? { matches.first { $0.sessionId == chosen } ?? (matches.count == 1 ? matches[0] : nil) }
    private var runningElsewhere: Bool {
        guard let id = match?.sessionId else { return false }
        return !store.tabs.contains { $0.sessionId == id } && Registry.running().contains { $0.sessionId == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resume a session").font(.title2.bold())
            Text("Paste a claude command or just a session ID; claude --continue picks up the folder's last conversation. Flags like --permission-mode are kept and reused whenever this tab restarts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("claude --permission-mode auto --resume 585bca13-…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(go)

            details
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(command.sessionId != nil ? "Resume" : continuing && lastInFolder != nil ? "Continue" : "Start New Session", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGo)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            // Pre-fill from the clipboard when it holds a claude command or a session ID.
            if let clip = NSPasteboard.general.string(forType: .string), clip.count < 400 {
                let parsed = ResumeCommand.parse(clip)
                if clip.contains("claude") || parsed.sessionId != nil && parsed.args.isEmpty { text = clip.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        .task(id: command.sessionId) {
            searched = false
            chosen = nil
            guard let id = command.sessionId else { matches = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            matches = SessionLookup.find(id)
            if let cwd = match?.cwd { folder = cwd }
            searched = true
        }
        .task(id: continuing ? folder : "") {
            guard continuing else { lastInFolder = nil; return }
            let dir = folder
            lastInFolder = await Task.detached { HistoryScanner.lastSession(in: dir) }.value
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !command.args.isEmpty {
                LabeledContent("Flags") {
                    Text(command.args.joined(separator: " ")).font(.system(.callout, design: .monospaced))
                }
            }
            if command.sessionId == nil {
                LabeledContent("Folder") { folderPicker }
                if !continuing {
                    Text("No session ID given, so this starts a new session.").font(.callout).foregroundStyle(.secondary)
                } else if let last = lastInFolder {
                    LabeledContent("Continues") { Text(store.historyName(last)).lineLimit(1) }
                    Text("The most recent conversation in this folder.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("No earlier conversation in this folder, so this starts a new session.").font(.callout).foregroundStyle(.secondary)
                }
            } else if !searched {
                ProgressView().controlSize(.small)
            } else if matches.isEmpty {
                Label("No saved conversation found with that ID.", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            } else if matches.count > 1 && chosen == nil {
                Text("Several sessions start with that ID. Pick one:").font(.callout)
                ForEach(matches, id: \.sessionId) { m in
                    Button { chosen = m.sessionId; if let c = m.cwd { folder = c } } label: {
                        Text("\(m.title ?? m.sessionId)  —  \((m.cwd ?? "?") as NSString).lastPathComponent)")
                    }
                    .buttonStyle(.link)
                }
            } else if let m = match {
                LabeledContent("Session") { Text(m.title ?? m.sessionId).lineLimit(1) }
                LabeledContent("Folder") {
                    if m.cwd != nil {
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                    } else {
                        folderPicker
                    }
                }
                if store.tabs.contains(where: { $0.sessionId == m.sessionId }) {
                    Text("Already open in Tabwise; this jumps to that tab.").font(.callout).foregroundStyle(.secondary)
                }
                if runningElsewhere {
                    Toggle("It's running in another window — quit it there first", isOn: $quitOriginal)
                }
            }
        }
    }

    private var folderPicker: some View {
        HStack {
            Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
            Button("Choose…") {
                if let dir = AppActions.pickFolder(title: "Choose the folder for this session") { folder = dir }
            }
        }
    }

    private var canGo: Bool {
        if command.sessionId == nil { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return match != nil
    }

    private func go() {
        guard canGo else { return }
        var cmd = command
        if continuing {
            store.continueLast(in: folder, args: cmd.args)
            dismiss()
            return
        }
        if let m = match { cmd.sessionId = m.sessionId }
        store.resume(cmd, cwd: folder, quitOriginal: quitOriginal)
        dismiss()
    }
}

// MARK: Search

/// The sidebar's search box, shared by Open and All Sessions: the same query and options in both.
struct SearchBar<Trailing: View>: View {
    @ObservedObject var store: DeckStore
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all sessions, open or not", text: $store.search).textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: store.searchFocusRequest) { focused = true }
                .onExitCommand { store.search = ""; focused = false }
            if store.deepSearching { ProgressView().controlSize(.mini) }
            if !store.search.isEmpty {
                Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Button { store.deepSearch.toggle() } label: {
                Image(systemName: "text.magnifyingglass").foregroundStyle(store.deepSearch ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.deepSearch ? "Searching inside whole conversations (click to search names only)"
                                   : "Search inside whole conversations too")
            trailing
        }
        .padding(6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
    }
}

/// A search result in the Open list for a conversation that isn't open in a tab; clicking resumes it.
struct ClosedSessionRow: View {
    @ObservedObject var store: DeckStore
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                .frame(width: 8, height: 8).padding(.top, 5).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.historyName(item)).lineLimit(1)
                if let note = store.history.note(item.id) { NoteLabel(note: note) }
                HStack(spacing: 4) {
                    FolderLabel(text: item.folderName, color: store.folderColors.color(for: item.cwd))
                    Spacer(minLength: 4)
                    Text(TabRow.relative(item.lastActive)).fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let hit = store.searchHit(item.id) {
                    Text(hit).font(.caption).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                } else if let last = item.lastPrompt {
                    Text("You: " + last).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { store.resumeHistory(item) }
        .help("Not open — click to resume it in a new tab")
        .selectionDisabled()
    }
}

// MARK: All Sessions

struct HistoryList: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var history: HistoryStore
    @State private var project: String?
    @AppStorage("historyShowEmpty") private var showEmpty = false
    @AppStorage("historyPinnedExpanded") private var pinnedExpanded = true
    @State private var renaming: HistoryItem?
    @State private var renameText = ""
    @State private var notingItem: HistoryItem?
    @State private var noteText = ""

    private var filtered: [HistoryItem] {
        history.items
            .filter { showEmpty || !$0.isTrivial }
            .filter { project == nil || $0.cwd == project }
            .filter(store.matches)
    }

    var body: some View {
        let all = filtered
        // Pinned sessions stay visible even if they'd be hidden for having one message.
        let pinPool = !store.isSearching && project == nil ? history.items : all
        let byId = Dictionary(pinPool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = history.meta.pinned.compactMap { byId[$0] }
        let rest = all.filter { !history.isPinned($0.id) }.sorted { $0.lastActive > $1.lastActive }
        List(selection: $store.selectedHistoryID) {
            if !pinned.isEmpty {
                Section(isExpanded: $pinnedExpanded) {
                    ForEach(pinned) { row($0) }
                        .onMove { history.movePinned(from: $0, to: $1, visible: pinned.map(\.id)) }
                } header: { SectionHeader(title: "Pinned (\(pinned.count))", icon: "pin.fill", expanded: $pinnedExpanded) }
            }
            Section {
                ForEach(rest) { row($0) }
            } header: {
                HStack {
                    Text(project.map { ($0 as NSString).lastPathComponent } ?? "All")
                    Text("\(rest.count)").foregroundStyle(.tertiary)
                    Spacer()
                    if history.scanning { ProgressView().controlSize(.mini) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 4) { SearchBar(store: store) { filterMenu } }
        .onAppear { history.refresh() }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let item = renaming {
                    history.setName(item.id, renameText)
                    if let tab = store.openTab(for: item.id) { tab.customName = history.name(item.id); store.scheduleSave() }
                }
            }
            Button("Use automatic name") { if let item = renaming { history.setName(item.id, nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Note", isPresented: Binding(get: { notingItem != nil }, set: { if !$0 { notingItem = nil } })) {
            TextField("e.g. waiting on client reply", text: $noteText)
            Button("Save") { if let item = notingItem { history.setNote(item.id, noteText) } }
            Button("Remove Note") { if let item = notingItem { history.setNote(item.id, nil) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filterMenu: some View {
        Menu {
            Button { project = nil } label: { Label("All Projects", systemImage: project == nil ? "checkmark" : "") }
            Divider()
            let folders = Dictionary(grouping: history.items.filter { showEmpty || !$0.isTrivial }.compactMap(\.cwd), by: { $0 })
                .map { (path: $0.key, count: $0.value.count) }
                .sorted { ($0.path as NSString).lastPathComponent.lowercased() < ($1.path as NSString).lastPathComponent.lowercased() }
            ForEach(folders, id: \.path) { f in
                Button { project = f.path } label: {
                    Label("\((f.path as NSString).lastPathComponent)  (\(f.count))", systemImage: project == f.path ? "checkmark" : "")
                }
            }
            Divider()
            Toggle("Show sessions with only one message", isOn: $showEmpty)
        } label: {
            Image(systemName: project == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by project")
    }

    private func row(_ item: HistoryItem) -> some View {
        let open = store.openTab(for: item.id)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(open == nil ? Color.clear : (open!.archived ? Color.gray.opacity(0.5) : Color.green.opacity(0.8)))
                .overlay(Circle().stroke(Color.secondary.opacity(open == nil ? 0.35 : 0), lineWidth: 1))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(open == nil ? "Not open" : open!.archived ? "Archived tab" : "Open in a tab")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.historyName(item)).lineLimit(1)
                if let note = history.note(item.id) { NoteLabel(note: note) }
                HStack(spacing: 4) {
                    FolderLabel(text: item.folderName, color: store.folderColors.color(for: item.cwd))
                    Spacer(minLength: 4)
                    Text(TabRow.relative(item.lastActive)).fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let hit = store.searchHit(item.id) {
                    Text(hit).font(.caption).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                } else if let last = item.lastPrompt {
                    Text("You: " + last).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .tag(item.id)
        .contextMenu {
            Button(open == nil ? "Resume in New Tab" : "Go to Tab") { store.resumeHistory(item) }
            Button("Start New Session in This Folder") { store.newSession(inFolderOf: item.cwd) }
                .disabled(item.cwd.map { !Bounded.exists($0) } ?? true)
            Button(history.isPinned(item.id) ? "Unpin" : "Pin to Top") { history.togglePin(item.id) }
            Button("Rename…") { renameText = store.historyName(item); renaming = item }
            FolderColorMenu(colors: store.folderColors, path: item.cwd)
            Button(history.note(item.id) == nil ? "Add Note…" : "Edit Note…") {
                noteText = history.note(item.id) ?? ""; notingItem = item
            }
            Divider()
            if let cwd = item.cwd {
                Button("Reveal Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd) }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.id, forType: .string)
            }
            Button("Copy Resume Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("cd \(ResumeCommand.shellQuote(item.cwd ?? "~")) && claude --resume \(item.id)", forType: .string)
            }
        }
    }
}

struct HistoryDetail: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        ZStack {
            Color(nsColor: Theme.background).ignoresSafeArea()
            if let id = store.selectedHistoryID, let item = history.items.first(where: { $0.id == id }) {
                detail(item)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("\(history.items.filter { !$0.isTrivial }.count) past sessions").font(.title2)
                    Text("Pick one on the left to see what it was about and resume it.").foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func detail(_ item: HistoryItem) -> some View {
        let folderExists = item.cwd.map { Bounded.exists($0) } ?? false
        let open = store.openTab(for: item.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.historyName(item)).font(.title.bold()).textSelection(.enabled)
                    if history.isPinned(item.id) { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                }
                if let note = history.note(item.id) { NoteLabel(note: note).font(.body) }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("Folder").foregroundStyle(.secondary); Text(((item.cwd ?? "unknown") as NSString).abbreviatingWithTildeInPath).textSelection(.enabled) }
                    if let c = item.created {
                        GridRow { Text("Started").foregroundStyle(.secondary); Text(c.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    GridRow { Text("Last message").foregroundStyle(.secondary); Text(item.lastActive.formatted(date: .abbreviated, time: .shortened)) }
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) }
                    GridRow { Text("Session ID").foregroundStyle(.secondary); Text(item.id).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
                HStack {
                    Button(open == nil ? "Resume in New Tab" : (open!.archived ? "Unarchive and Resume" : "Go to Tab")) {
                        store.resumeHistory(item)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!folderExists)
                    Button("New Session in This Folder") { store.newSession(inFolderOf: item.cwd) }
                        .disabled(!folderExists)
                    Button(history.isPinned(item.id) ? "Unpin" : "Pin to Top") { history.togglePin(item.id) }
                    if !folderExists { Text("The folder no longer exists.").foregroundStyle(.orange) }
                }
                if let first = item.firstPrompt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("First message").font(.headline)
                        Text(first).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
                if let last = item.lastPrompt, last != item.firstPrompt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last message").font(.headline)
                        Text(last).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
