import Foundation
import AppKit

/// Backs up Tabwise's own data and your real conversations to iCloud Drive (or a folder you choose),
/// and restores both on a new Mac.
///
/// Layout of the backup folder:
///   manifest.json                    who/when
///   app/                             tabs, closed tabs, names/pins/notes, prompts, preferences
///   conversations/<project>/…        transcripts (+ subagent runs and Claude's per-project memory)
@MainActor
final class BackupManager: ObservableObject {
    struct Manifest: Codable {
        var machine: String
        var user: String
        var home: String
        var date: Date
        var tabs: Int
        var conversations: Int
        var bytes: Int64
    }

    @Published private(set) var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackupDate") as? Date
    @Published private(set) var lastBytes: Int64 = Int64(UserDefaults.standard.integer(forKey: "lastBackupBytes"))
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published var restoreProgress: (done: Int, total: Int)?

    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "backupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backupEnabled") }
    }
    static var includeConversations: Bool {
        get { UserDefaults.standard.object(forKey: "backupConversations") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backupConversations") }
    }
    /// A custom destination (e.g. a Dropbox folder); nil means iCloud Drive.
    static var customFolder: String? {
        get { UserDefaults.standard.string(forKey: "backupFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "backupFolder") }
    }

    static var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }

    /// Where backups go, or nil if iCloud Drive is off and no other folder was chosen.
    static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["TABWISE_BACKUP_DIR"] { return URL(fileURLWithPath: override) }
        if let custom = customFolder { return URL(fileURLWithPath: custom).appendingPathComponent("Tabwise Backup") }
        return iCloudAvailable ? iCloudDrive.appendingPathComponent("Tabwise Backup") : nil
    }

    static var destinationName: String {
        if let custom = customFolder { return (custom as NSString).abbreviatingWithTildeInPath }
        return "iCloud Drive"
    }

    private static let appFiles = ["tabs.json", "closed.json", "history.json", "prompts.json"]
    /// Preferences worth carrying to another Mac.
    private static let prefKeys = ["defaultCommand", "autoArchiveDays", "builtInStatusLine", "keepAwake", "folderColors",
                                   "folderColorSlots", "sidebarLayout", "fontSize", "historyShowEmpty", "historyDeepSearch",
                                   "splitVertical", "splitFraction", "selectedTab"]
    private var stateDir: URL { DeckStore.stateURL.deletingLastPathComponent() }

    // MARK: Backup

    /// Small and cheap: copies Tabwise's own files when they changed. Written in place (not atomically):
    /// replacing files would fill iCloud's Recently Deleted.
    func backupAppData(tabCount: Int) {
        guard Self.enabled, let root = Self.root else { return }
        let fm = FileManager.default
        let app = root.appendingPathComponent("app")
        try? fm.createDirectory(at: app, withIntermediateDirectories: true)
        for name in Self.appFiles {
            let src = stateDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: src) else { continue }
            let dst = app.appendingPathComponent(name)
            if (try? Data(contentsOf: dst)) != data { try? data.write(to: dst) }
        }
        var prefs: [String: Any] = [:]
        for key in Self.prefKeys { if let v = UserDefaults.standard.object(forKey: key) { prefs[key] = v } }
        if let data = try? PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0) {
            let dst = app.appendingPathComponent("preferences.plist")
            if (try? Data(contentsOf: dst)) != data { try? data.write(to: dst) }
        }
        writeManifest(root: root, tabs: tabCount, conversations: nil, bytes: nil)
    }

    /// Copies new or grown transcripts (append-only, so bigger = newer), their subagent runs, and
    /// Claude's per-project memory. Runs in the background.
    func backupConversations(sessionIds: Set<String>, items: [HistoryItem], tabCount: Int) {
        guard Self.enabled, Self.includeConversations, !running, let root = Self.root else { return }
        running = true
        status = "Backing up conversations…"
        let paths = items.filter { sessionIds.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        Task.detached(priority: .background) {
            let dest = root.appendingPathComponent("conversations")
            var bytes: Int64 = 0
            var projects = Set<URL>()
            for src in paths {
                let project = src.deletingLastPathComponent()
                projects.insert(project)
                let target = dest.appendingPathComponent(project.lastPathComponent)
                bytes += Self.mirror(src, to: target.appendingPathComponent(src.lastPathComponent))
                // Subagent runs live in <project>/<session>/…
                let sessionDir = project.appendingPathComponent(src.deletingPathExtension().lastPathComponent)
                bytes += Self.mirrorTree(sessionDir, to: target.appendingPathComponent(sessionDir.lastPathComponent))
            }
            for project in projects {
                bytes += Self.mirrorTree(project.appendingPathComponent("memory"),
                                         to: dest.appendingPathComponent(project.lastPathComponent).appendingPathComponent("memory"))
            }
            let total = bytes
            let count = paths.count
            await MainActor.run {
                self.running = false
                self.status = nil
                self.lastBackup = Date()
                self.lastBytes = total
                UserDefaults.standard.set(Date(), forKey: "lastBackupDate")
                UserDefaults.standard.set(Int(total), forKey: "lastBackupBytes")
                self.writeManifest(root: root, tabs: tabCount, conversations: count, bytes: total)
            }
        }
    }

    /// Bring `dst` up to date with `src`. Returns the file's size.
    /// Never deletes or replaces the copy: in iCloud a replaced file lands in Recently Deleted and keeps
    /// using storage for 30 days. Transcripts only ever grow, so usually just the new tail is appended.
    nonisolated private static func mirror(_ src: URL, to dst: URL) -> Int64 {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: src.path), let size = (a[.size] as? NSNumber)?.int64Value else { return 0 }
        let srcDate = a[.modificationDate] as? Date ?? .distantPast
        let dstSize = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value
        if let dstSize, dstSize == size,
           ((try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date ?? .distantPast) >= srcDate {
            return size
        }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let dstSize, dstSize > 0, dstSize < size, sameStart(src, dst, length: dstSize),
           let reader = try? FileHandle(forReadingFrom: src), let writer = try? FileHandle(forWritingTo: dst) {
            // Append only what's new.
            defer { try? reader.close(); try? writer.close() }
            try? reader.seek(toOffset: UInt64(dstSize))
            try? writer.seekToEnd()
            while let chunk = try? reader.read(upToCount: 4 << 20), !chunk.isEmpty { try? writer.write(contentsOf: chunk) }
        } else if dstSize != nil {
            // Changed some other way: rewrite the same file in place (not atomically, so it isn't replaced).
            guard let data = try? Data(contentsOf: src), let writer = try? FileHandle(forWritingTo: dst) else { return 0 }
            try? writer.truncate(atOffset: 0)
            try? writer.write(contentsOf: data)
            try? writer.close()
        } else {
            guard (try? fm.copyItem(at: src, to: dst)) != nil else { return 0 }
        }
        try? fm.setAttributes([.modificationDate: srcDate], ofItemAtPath: dst.path)
        return size
    }

    /// Whether the last 64 KB before `length` match, i.e. `dst` is an older, shorter copy of `src`.
    nonisolated private static func sameStart(_ src: URL, _ dst: URL, length: Int64) -> Bool {
        func tail(_ url: URL) -> Data? {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            let n = min(length, 64 * 1024)
            try? h.seek(toOffset: UInt64(length - n))
            return try? h.read(upToCount: Int(n))
        }
        guard let a = tail(src), let b = tail(dst) else { return false }
        return a == b
    }

    nonisolated private static func mirrorTree(_ src: URL, to dst: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue,
              let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && !file.lastPathComponent.hasPrefix(".") { // skip lock and temp files
            let rel = file.path.dropFirst(src.path.count + 1)
            bytes += mirror(file, to: dst.appendingPathComponent(String(rel)))
        }
        return bytes
    }

    private func writeManifest(root: URL, tabs: Int, conversations: Int?, bytes: Int64?) {
        let url = root.appendingPathComponent("manifest.json")
        let old = Self.readManifest(root)
        let m = Manifest(machine: Host.current().localizedName ?? "Mac", user: NSUserName(),
                         home: NSHomeDirectory(), date: Date(), tabs: tabs,
                         conversations: conversations ?? old?.conversations ?? 0, bytes: bytes ?? old?.bytes ?? 0)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(m) { try? data.write(to: url) }
    }

    static func readManifest() -> Manifest? { readManifest(root) }

    static func readManifest(_ root: URL?) -> Manifest? {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Manifest.self, from: data)
    }

    // MARK: Restore

    /// Restores Tabwise's data and copies conversations back into ~/.claude/projects.
    /// Paths from a Mac with a different user name are rewritten to this one.
    /// Conversations of the restored tabs come first so they can resume right away; `ready` runs after those.
    func restore(ready: @escaping @MainActor () -> Void) {
        guard let root = Self.root, let manifest = Self.readManifest(root) else { ready(); return }
        let fm = FileManager.default
        let oldHome = manifest.home, newHome = NSHomeDirectory()
        func remap(_ s: String) -> String { oldHome == newHome ? s : s.replacingOccurrences(of: oldHome, with: newHome) }
        func encode(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
        let encOld = encode(oldHome), encNew = encode(newHome)

        // 1. App data (only fills in what this Mac doesn't have yet).
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("app")
        for name in Self.appFiles {
            let dst = stateDir.appendingPathComponent(name)
            let existing = (try? Data(contentsOf: dst)).flatMap { String(data: $0, encoding: .utf8) }
            guard existing == nil || existing == "[]" || existing == "{}",
                  let data = try? Data(contentsOf: app.appendingPathComponent(name)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            try? remap(text).write(to: dst, atomically: true, encoding: .utf8)
        }
        if let data = try? Data(contentsOf: app.appendingPathComponent("preferences.plist")),
           let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (k, v) in prefs where UserDefaults.standard.object(forKey: k) == nil || k == "selectedTab" {
                if k == "folderColors" || k == "folderColorSlots", let dict = v as? [String: Any] {
                    UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: dict.map { (remap($0.key), $0.value) }), forKey: k)
                } else {
                    UserDefaults.standard.set(v, forKey: k)
                }
            }
        }

        // 2. Conversations: every file under conversations/, open tabs' sessions first.
        let convRoot = root.appendingPathComponent("conversations")
        let prioritySessions = Set(((try? JSONDecoder().decode([SavedTab].self,
                                                                from: Data(contentsOf: stateDir.appendingPathComponent("tabs.json")))) ?? [])
            .compactMap(\.sessionId))
        var files: [URL] = []
        if let walker = fm.enumerator(at: convRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in walker where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !f.lastPathComponent.hasPrefix(".") {
                files.append(f)
            }
        }
        func isPriority(_ f: URL) -> Bool { prioritySessions.contains { f.path.contains($0) } }
        let priority = files.filter(isPriority), rest = files.filter { !isPriority($0) }
        let total = files.count
        restoreProgress = (0, total)
        let base = convRoot.path
        Task.detached(priority: .userInitiated) {
            var done = 0
            func copy(_ list: [URL]) async {
                for f in list {
                    var rel = String(f.path.dropFirst(base.count + 1))
                    if encOld != encNew, rel.hasPrefix(encOld) { rel = encNew + rel.dropFirst(encOld.count) }
                    let target = ProcessInfo.processInfo.environment["TABWISE_TEST_PROJECTS_DIR"].map { URL(fileURLWithPath: $0) }
                        ?? Registry.projectsDir // test hook: restore somewhere harmless
                    let dst = target.appendingPathComponent(rel)
                    // Never shrink a local transcript: only copy when missing or the backup is bigger.
                    let local = ((try? FileManager.default.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? -1
                    let remote = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    if remote > local { _ = Self.mirror(f, to: dst) }
                    done += 1
                    let d = done
                    if d % 10 == 0 || d == total { await MainActor.run { self.restoreProgress = (d, total) } }
                }
            }
            await copy(priority)
            await MainActor.run { ready() }
            await copy(rest)
            await MainActor.run { self.restoreProgress = nil }
        }
    }
}
