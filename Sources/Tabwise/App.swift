import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import Combine
import Sparkle

@MainActor
enum AppActions {
    static var lastFolder: String {
        get { UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: "lastFolder") }
    }

    static func pickFolder(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = title
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: lastFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastFolder = url.path
        return url.path
    }

    /// New session: pick a folder, optionally continuing its last conversation (a checkbox in the panel).
    static func newSession(_ store: DeckStore, continueLast: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to start Claude in"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: lastFolder)
        let checkbox = NSButton(checkboxWithTitle: "Continue the last conversation in this folder (claude --continue)",
                                target: nil, action: nil)
        checkbox.state = continueLast ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.fittingSize.width + 40, height: checkbox.fittingSize.height + 16))
        checkbox.frame.origin = NSPoint(x: 20, y: 8)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.path
        if checkbox.state == .on { store.continueLast(in: url.path) } else { store.newClaude(in: url.path) }
    }

    static func newShell(_ store: DeckStore) {
        store.newShell(in: store.selected?.cwd ?? lastFolder)
    }

    /// ⌘S: sleep a running tab (asking first if Claude is mid-reply), or wake a sleeping one.
    static func toggleSleep(_ tab: SessionTab, store: DeckStore) {
        if tab.status == .notStarted { store.wake(tab); return }
        if tab.status == .working {
            let alert = NSAlert()
            alert.messageText = "Put “\(tab.displayName)” to sleep?"
            alert.informativeText = "Claude is still working in this tab; its current reply will be interrupted. Everything up to now is kept, and waking the tab resumes the conversation."
            alert.addButton(withTitle: "Put to Sleep")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.sleep(tab)
    }

    static func copySessionID(_ tab: SessionTab) {
        guard let id = tab.sessionId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

    static func close(_ tab: SessionTab, store: DeckStore) {
        if tab.status == .working {
            let alert = NSAlert()
            alert.messageText = "Close “\(tab.displayName)”?"
            alert.informativeText = "Claude is still working in this tab. You can resume the conversation later with claude --resume."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.close(tab)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let store = DeckStore()
    /// Sparkle auto-updates (feed and public key are in Info.plist).
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Tabwise"
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.delegate = self
        window.setFrameAutosaveName("TabwiseMain")
        if !window.setFrameUsingName("TabwiseMain") { window.center() }
        window.makeKeyAndOrderFront(nil)

        // Open at Login is on by default (once); the user can switch it off in the app menu.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }

        // README screenshots: show the demo window on whatever Space is active (even over full-screen apps).
        if Demo.tabs != nil {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.level = .floating
            window.orderFrontRegardless()
        }
        Migration.offerRemovingOldApp()
        setupStatusItem()
        store.onPolled = { [weak self] in self?.updateStatusItem() }
        // A fresh install with a backup available (e.g. a new Mac): offer to restore everything.
        if !FileManager.default.fileExists(atPath: DeckStore.stateURL.path) || (try? Data(contentsOf: DeckStore.stateURL)) == Data("[]".utf8),
           BackupManager.enabled, let manifest = BackupManager.readManifest() {
            let alert = NSAlert()
            alert.messageText = "Restore from \(BackupManager.destinationName)?"
            alert.informativeText = "A Tabwise backup from “\(manifest.machine)” (\(manifest.date.formatted(date: .abbreviated, time: .shortened))) has \(manifest.tabs) tab(s) and \(manifest.conversations) conversation(s). Restore your tabs, names, pins, notes, prompts, settings and conversations?"
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Start Fresh")
            let autoRestore = ProcessInfo.processInfo.environment["TABWISE_TEST_AUTORESTORE"] != nil // test hook
            if autoRestore || alert.runModal() == .alertFirstButtonReturn {
                store.backup.restore { [weak self] in self?.store.launch() }
            } else {
                store.launch()
            }
        } else {
            store.launch()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) { store.appBecameActive(); ActiveSession.publish(store) }
    func applicationDidResignActive(_ notification: Notification) { ActiveSession.publish(store) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = store.tabs.filter { $0.status == .working }
        // Never block a restart, shutdown or logout with a dialog; everything is saved either way.
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        if !working.isEmpty && !systemQuit {
            let alert = NSAlert()
            alert.messageText = "Quit Tabwise?"
            alert.informativeText = "\(working.count) session(s) are still working: " +
                working.map(\.displayName).joined(separator: ", ") +
                ".\nAll tabs will be resumed next time you open the app."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.shutdown()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Show banners even while the app is frontmost (for tabs you're not looking at).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo["tab"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let idString, let id = UUID(uuidString: idString) { self.store.selectedID = id }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    // MARK: Menu actions

    @objc func newSession(_ sender: Any?) { AppActions.newSession(store) }
    @objc func continueSession(_ sender: Any?) { AppActions.newSession(store, continueLast: true) }
    @objc func newSessionHere(_ sender: Any?) {
        if store.sidebarMode == .history, let id = store.selectedHistoryID,
           let item = store.history.items.first(where: { $0.id == id }) {
            store.newSession(inFolderOf: item.cwd)
        } else {
            store.newSession(inFolderOf: store.selected?.cwd ?? AppActions.lastFolder, args: store.selected?.extraArgs ?? [])
        }
    }
    @objc func newShell(_ sender: Any?) { AppActions.newShell(store) }
    @objc func importSessions(_ sender: Any?) { store.showImport = true }
    @objc func resumeSession(_ sender: Any?) { store.showResume = true }
    @objc func togglePin(_ sender: Any?) { if let t = store.selected { store.togglePin(t) } }
    @objc func archiveTab(_ sender: Any?) { if let t = store.selected { store.archive(t) } }
    @objc func showOpenTabs(_ sender: Any?) { store.sidebarMode = .open }
    @objc func quickSwitch(_ sender: Any?) { store.showSwitcher = true }
    @objc func toggleSplit(_ sender: Any?) { store.toggleSplit() }
    @objc func toggleSplitOrientation(_ sender: Any?) { store.splitVertical.toggle() }
    @objc func jumpToNeedsYou(_ sender: Any?) { store.jumpToNeedsYou() }
    @objc func sendToSeveral(_ sender: Any?) { store.showBroadcast = true }
    @objc func insertPrompt(_ sender: NSMenuItem) {
        guard let tab = store.selected, !tab.archived, store.prompts.prompts.indices.contains(sender.tag) else { NSSound.beep(); return }
        tab.terminal.insert(store.prompts.prompts[sender.tag].text, submit: false)
    }
    private var settingsWindow: NSWindow?
    @objc func backupNow(_ sender: Any?) { store.backupConversationsNow() }
    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Tabwise Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(prompts: store.prompts, store: store, updater: updater.updater, backup: store.backup))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showAllSessions(_ sender: Any?) { store.sidebarMode = .history }
    @objc func setLayout(_ sender: NSMenuItem) {
        store.layout = sender.tag == 1 ? .projects : .recent
    }
    @objc func closeTab(_ sender: Any?) {
        if let tab = store.selected { AppActions.close(tab, store: store) } else { window.performClose(nil) }
    }
    @objc func restartTab(_ sender: Any?) { store.selected?.restart() }
    @objc func sleepTab(_ sender: Any?) { if let t = store.selected { AppActions.toggleSleep(t, store: store) } }
    @objc func renameTab(_ sender: Any?) { store.renameRequest = store.selected }
    @objc func noteTab(_ sender: Any?) { store.noteRequest = store.selected }
    @objc func copySessionID(_ sender: Any?) { if let t = store.selected { AppActions.copySessionID(t) } }
    @objc func revealTab(_ sender: Any?) {
        if let t = store.selected { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: t.cwd) }
    }
    @objc func sleepOthers(_ sender: Any?) { store.sleepOthers() }
    @objc func nextTab(_ sender: Any?) { store.selectRelative(1) }
    @objc func previousTab(_ sender: Any?) { store.selectRelative(-1) }
    @objc func selectTab(_ sender: NSMenuItem) { store.selectIndex(sender.tag) }
    @objc func biggerFont(_ sender: Any?) { Theme.fontSize = min(Theme.fontSize + 1, 32); store.applyFont() }
    @objc func smallerFont(_ sender: Any?) { Theme.fontSize = max(Theme.fontSize - 1, 8); store.applyFont() }
    @objc func resetFont(_ sender: Any?) { Theme.fontSize = 13; store.applyFont() }
    @objc func reopenClosed(_ sender: NSMenuItem) {
        store.reopenClosed(sender.representedObject as? UUID)
    }
    @objc func toggleOpenAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Rebuilds the "Recently Closed" submenu each time it opens.
    // MARK: Menu bar icon

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var statusTitle = ""

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Tabwise")
        item.button?.imagePosition = .imageLeading
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    /// "⚡2 ◉1" = two sessions working, one waiting for you.
    private func updateStatusItem() {
        let live = store.liveTabs
        let working = live.filter { $0.status == .working }.count
        let needs = live.filter { $0.needsAttention || $0.status == .waiting }.count
        let title = [working > 0 ? "⚡︎\(working)" : nil, needs > 0 ? "◉\(needs)" : nil].compactMap { $0 }.joined(separator: " ")
        guard title != statusTitle else { return }
        statusTitle = title
        statusItem?.button?.title = title.isEmpty ? "" : " " + title
        statusItem?.button?.image = NSImage(systemSymbolName: needs > 0 ? "rectangle.stack.badge.person.crop" : "rectangle.stack",
                                            accessibilityDescription: "Tabwise")
            ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Tabwise")
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        let live = store.ordered
        let groups: [(String, [SessionTab])] = [
            ("Needs you", live.filter { $0.needsAttention || $0.status == .waiting }),
            ("Working", live.filter { $0.status == .working && !$0.needsAttention }),
            ("Idle", live.filter { ![.working, .waiting].contains($0.status) && !$0.needsAttention }),
        ]
        for (title, tabs) in groups where !tabs.isEmpty {
            let header = NSMenuItem(title: "\(title) (\(tabs.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            statusMenu.addItem(header)
            for tab in tabs {
                let item = NSMenuItem(title: "  " + tab.displayName, action: #selector(selectFromStatus(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tab.id
                item.toolTip = tab.shortPath
                statusMenu.addItem(item)
            }
            statusMenu.addItem(.separator())
        }
        for (title, action) in [("Next Session That Needs You", #selector(jumpFromStatus(_:))),
                                ("Quick Switch…", #selector(switchFromStatus(_:))),
                                ("Open Tabwise", #selector(showFromStatus(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            statusMenu.addItem(item)
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit Tabwise", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func selectFromStatus(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.sidebarMode = .open
        store.selectedID = id
        bringToFront()
    }
    @objc func jumpFromStatus(_ sender: Any?) { bringToFront(); store.jumpToNeedsYou() }
    @objc func switchFromStatus(_ sender: Any?) { bringToFront(); store.showSwitcher = true }
    @objc func showFromStatus(_ sender: Any?) { bringToFront() }

    private weak var promptsMenu: NSMenu?
    private var promptsWatch: AnyCancellable?

    /// Kept populated at all times so ⌃⌘1…9 work without opening the menu first.
    private func rebuildPromptsMenu(_ prompts: [SavedPrompt]) {
        guard let menu = promptsMenu else { return }
        menu.removeAllItems()
        for (i, p) in prompts.enumerated() {
            let title = p.text.count > 60 ? String(p.text.prefix(60)) + "…" : p.text
            let item = NSMenuItem(title: title, action: #selector(insertPrompt(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        if prompts.isEmpty { menu.addItem(NSMenuItem(title: "No Saved Prompts", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let send = NSMenuItem(title: "Send to Several Sessions…", action: #selector(sendToSeveral(_:)), keyEquivalent: "b")
        send.keyEquivalentModifierMask = [.command, .shift]
        send.target = self
        menu.addItem(send)
        let manage = NSMenuItem(title: "Manage Prompts…", action: #selector(openSettings(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            rebuildStatusMenu()
            return
        }
        if menu === promptsMenu {
            rebuildPromptsMenu(store.prompts.prompts)
            return
        }
        menu.removeAllItems()
        if store.recentlyClosed.isEmpty {
            menu.addItem(NSMenuItem(title: "No Closed Tabs", action: nil, keyEquivalent: ""))
            return
        }
        for record in store.recentlyClosed {
            let folder = (record.cwd as NSString).lastPathComponent
            let item = NSMenuItem(title: "\(record.title ?? folder)  —  \(folder)", action: #selector(reopenClosed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.id
            menu.addItem(item)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSplit(_:)) {
            item.title = store.splitID == nil ? "Split View with Next Tab" : "Close Split View"
        }
        if item.action == #selector(toggleSplitOrientation(_:)) {
            item.title = store.splitVertical ? "Stack Split Top / Bottom" : "Split Side by Side"
            return store.splitID != nil
        }
        if item.action == #selector(setLayout(_:)) {
            item.state = (item.tag == 1) == (store.layout == .projects) ? .on : .off
        }
        if item.action == #selector(togglePin(_:)) {
            item.title = store.selected?.pinned == true ? "Unpin Tab" : "Pin Tab to Top"
            return store.selected.map { !$0.archived } ?? false
        }
        if item.action == #selector(sleepTab(_:)) {
            item.title = store.selected?.status == .notStarted ? "Wake Up Tab" : "Put Tab to Sleep"
            return store.selected.map { !$0.archived } ?? false
        }
        if item.action == #selector(noteTab(_:)) {
            let id = store.selected?.sessionId
            item.title = id.flatMap { store.history.note($0) } == nil ? "Add Note…" : "Edit Note…"
            return id != nil
        }
        if item.action == #selector(copySessionID(_:)) { return store.selected?.sessionId != nil }
        if [#selector(renameTab(_:)), #selector(revealTab(_:))].contains(item.action) { return store.selected != nil }
        if item.action == #selector(archiveTab(_:)) {
            return store.selected.map { !$0.archived } ?? false
        }
        if item.action == #selector(toggleOpenAtLogin(_:)) {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return true
    }

    @objc func openStateFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([DeckStore.stateURL])
    }

    private func buildMenu() {
        let main = NSMenu()

        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            item.tag = tag
            menu.addItem(item)
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        let app = submenu("Tabwise")
        add(app, "About Tabwise", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add(app, "Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)), target: updater)
        app.addItem(.separator())
        add(app, "Settings…", #selector(openSettings(_:)), ",", target: self)
        add(app, "Back Up Now", #selector(backupNow(_:)), target: self)
        add(app, "Open at Login", #selector(toggleOpenAtLogin(_:)), target: self)
        add(app, "Show Saved Tabs File", #selector(openStateFolder(_:)), target: self)
        app.addItem(.separator())
        add(app, "Hide Tabwise", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(.separator())
        add(app, "Quit Tabwise", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "New Claude Session…", #selector(newSession(_:)), "t", target: self)
        add(file, "New Claude Session in Same Folder", #selector(newSessionHere(_:)), "t", [.command, .control], target: self)
        add(file, "New Shell Tab", #selector(newShell(_:)), "t", [.command, .option], target: self)
        file.addItem(.separator())
        add(file, "Continue Last Session in Folder…", #selector(continueSession(_:)), "o", target: self)
        add(file, "Resume Session…", #selector(resumeSession(_:)), "r", target: self)
        add(file, "Import Sessions…", #selector(importSessions(_:)), "i", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Restart Tab", #selector(restartTab(_:)), "r", [.command, .shift], target: self)
        add(file, "Put Tab to Sleep", #selector(sleepTab(_:)), "s", target: self)
        add(file, "Put Other Tabs to Sleep", #selector(sleepOthers(_:)), "s", [.command, .option], target: self)
        add(file, "Rename Tab…", #selector(renameTab(_:)), "e", target: self)
        add(file, "Add Note…", #selector(noteTab(_:)), "n", [.command, .shift], target: self)
        add(file, "Copy Session ID", #selector(copySessionID(_:)), "c", [.command, .option], target: self)
        add(file, "Reveal in Finder", #selector(revealTab(_:)), "r", [.command, .option], target: self)
        add(file, "Pin / Unpin Tab", #selector(togglePin(_:)), "p", [.command, .shift], target: self)
        add(file, "Archive Tab", #selector(archiveTab(_:)), "a", [.command, .shift], target: self)
        add(file, "Close Tab", #selector(closeTab(_:)), "w", target: self)
        file.addItem(.separator())
        add(file, "Reopen Closed Tab", #selector(reopenClosed(_:)), "t", [.command, .shift], target: self)
        let recentItem = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Recently Closed")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        file.addItem(recentItem)

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Open Tabs", #selector(showOpenTabs(_:)), "1", [.command, .option], target: self)
        add(view, "All Sessions", #selector(showAllSessions(_:)), "2", [.command, .option], target: self)
        view.addItem(.separator())
        add(view, "Split View with Next Tab", #selector(toggleSplit(_:)), "d", target: self)
        add(view, "Side by Side / Stacked", #selector(toggleSplitOrientation(_:)), "d", [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "Most Recent First", #selector(setLayout(_:)), target: self, tag: 0)
        add(view, "Group by Folder", #selector(setLayout(_:)), target: self, tag: 1)
        view.addItem(.separator())
        add(view, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        view.addItem(.separator())
        add(view, "Bigger Text", #selector(biggerFont(_:)), "+", target: self)
        add(view, "Smaller Text", #selector(smallerFont(_:)), "-", target: self)
        add(view, "Default Text Size", #selector(resetFont(_:)), "0", target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let go = submenu("Go")
        add(go, "Quick Switch…", #selector(quickSwitch(_:)), "k", target: self)
        add(go, "Next Session That Needs You", #selector(jumpToNeedsYou(_:)), "j", target: self)

        let promptsItem = NSMenuItem(title: "Prompts", action: nil, keyEquivalent: "")
        let promptsMenu = NSMenu(title: "Prompts")
        promptsMenu.delegate = self
        promptsItem.submenu = promptsMenu
        main.addItem(promptsItem)
        self.promptsMenu = promptsMenu
        promptsWatch = store.prompts.$prompts.receive(on: DispatchQueue.main).sink { [weak self] in self?.rebuildPromptsMenu($0) }

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Next Tab", #selector(nextTab(_:)), "]", [.command, .shift], target: self)
        add(window, "Previous Tab", #selector(previousTab(_:)), "[", [.command, .shift], target: self)
        add(window, "Next Tab", #selector(nextTab(_:)), "\t", .control, target: self)
        add(window, "Previous Tab", #selector(previousTab(_:)), "\t", [.control, .shift], target: self)
        window.addItem(.separator())
        for i in 0..<9 { add(window, "Tab \(i + 1)", #selector(selectTab(_:)), "\(i + 1)", target: self, tag: i) }
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}

@main
struct Main {
    static func main() {
        Migration.run() // before anything reads settings or saved tabs
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
