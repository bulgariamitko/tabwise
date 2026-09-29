import Foundation
import AppKit
import SQLite3

/// One-time move from the app's earlier name ("Claude Deck", bundle com.dimitar.claudedeck) to Tabwise:
/// preferences, tabs/pins/names/notes/prompts, and the backup folder come along, so nothing is lost.
/// Also copies session names from the claude.json editor app once. Does nothing on a clean install.
enum Migration {
    private static let oldBundle = "com.dimitar.claudedeck" as CFString

    /// `dryRun` (tests): don't quit the old app or move the backup folder.
    static func run(dryRun: Bool = false) {
        let env = ProcessInfo.processInfo.environment
        guard env["TABWISE_STATE_DIR"] == nil else { return } // test runs use their own data
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromClaudeDeck") else { return }
        defer { defaults.set(true, forKey: "migratedFromClaudeDeck") }
        let fm = FileManager.default

        // Quit the old app first so it saves its tabs and stops backing up to the old folder.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundle as String)
        if !dryRun { running.forEach { $0.terminate() } }
        let deadline = Date().addingTimeInterval(15)
        while !dryRun && running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        // Preferences (not the login-item flag: Tabwise registers its own login item).
        if let keys = CFPreferencesCopyKeyList(oldBundle, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys where key != "loginItemConfigured" {
                guard let value = CFPreferencesCopyAppValue(key as CFString, oldBundle) else { continue }
                let newKey = key == "NSWindow Frame ClaudeDeckMain" ? "NSWindow Frame TabwiseMain" : key
                if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            }
        }

        // App data: copied (not moved), so the old app still works if you open it again.
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("ClaudeDeck"), new = support.appendingPathComponent("Tabwise")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.appendingPathComponent("tabs.json").path) {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where name != "usage-index.json" { // cost tracking was removed
                let dst = new.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: old.appendingPathComponent(name), to: dst) }
            }
        }

        // Backup folder: renamed in place (no re-upload to iCloud).
        var bases = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")]
        if let custom = defaults.string(forKey: "backupFolder") { bases.append(URL(fileURLWithPath: custom)) }
        for base in bases {
            let from = base.appendingPathComponent("Claude Deck Backup"), to = base.appendingPathComponent("Tabwise Backup")
            if !dryRun, fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: from, to: to) }
        }

        if fm.fileExists(atPath: old.path) { defaults.set(true, forKey: "offerRemovingOldApp") }

        // Names from the claude.json editor become Tabwise's own names (never overriding yours).
        let names = EditorBridge.read().compactMapValues(\.name)
        let historyURL = new.appendingPathComponent("history.json")
        if !names.isEmpty {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: historyURL))) as? [String: Any] ?? [:]
            var current = meta["names"] as? [String: String] ?? [:]
            for (id, name) in names where current[id] == nil { current[id] = name }
            meta["names"] = current
            if meta["pinned"] == nil { meta["pinned"] = [String]() }
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: historyURL, options: .atomic)
            }
        }
    }

    /// After moving over: offer (once) to put the old app in the Trash, which also ends its login item.
    @MainActor static func offerRemovingOldApp() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "offerRemovingOldApp") else { return }
        defaults.set(false, forKey: "offerRemovingOldApp")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: oldBundle as String) else { return }
        let alert = NSAlert()
        alert.messageText = "Claude Deck is now Tabwise"
        alert.informativeText = "Your tabs, names, pins, notes, prompts, settings and backup were moved over. Move the old “\(url.lastPathComponent)” to the Trash? (Otherwise it would still open at login.)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.recycle([url]) }
    }
}

/// Reads (never writes) the names you set in the claude.json editor app, which keeps them in
/// its WebKit localStorage under "claudeJsonEditor.sessionMeta".
enum EditorBridge {
    struct Entry { var starred: Bool; var name: String? }

    static let storageDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/WebKit/com.dimitarklaturov.claudejsoneditor/WebsiteData/Default")

    /// Starred flags and names, by session id.
    static func read() -> [String: Entry] {
        guard let text = value(forKey: "claudeJsonEditor.sessionMeta"),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]] else { return [:] }
        var result: [String: Entry] = [:]
        for (id, meta) in json {
            let name = (meta["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            result[id] = Entry(starred: meta["starred"] as? Bool ?? false, name: name?.isEmpty == false ? name : nil)
        }
        return result
    }

    /// One localStorage value from the editor, or nil.
    static func value(forKey key: String) -> String? {
        let fm = FileManager.default
        // …/Default/<origin>/<origin>/LocalStorage/localstorage.sqlite3
        guard let enumerator = fm.enumerator(at: storageDir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "localstorage.sqlite3" {
            if let v = readDB(url, key: key) { return v }
        }
        return nil
    }

    private static func readDB(_ db: URL, key: String) -> String? {
        // Work on a copy (with its WAL) so the editor's live database is never locked or modified.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("claudedeck-editor-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: tmp.appendingPathComponent("ls.sqlite3" + suffix))
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open(tmp.appendingPathComponent("ls.sqlite3").path, &handle) == SQLITE_OK else { return nil }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        // WebKit stores localStorage values as UTF-16LE.
        return String(data: data, encoding: .utf16LittleEndian)
    }
}

