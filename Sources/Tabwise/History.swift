import Foundation
import AppKit

/// One past conversation on disk (~/.claude/projects/<folder>/<sessionId>.jsonl).
struct HistoryItem: Codable, Identifiable, Hashable {
    var id: String            // session id
    var path: String          // transcript file
    var cwd: String?
    var title: String?        // /rename title, else Claude's AI title
    var firstPrompt: String?
    var lastPrompt: String?
    var created: Date?
    var lastUserAt: Date?
    var mtime: Date
    var size: Int
    /// Entry ids of your first and last typed message; equal means you sent just one.
    var firstUUID: String?
    var lastUUID: String?
    var entrypoint: String?   // "cli" for interactive, "sdk-cli" for automated runs

    /// When you last talked to it; falls back to the file's modification time.
    var lastActive: Date { lastUserAt ?? mtime }
    /// Sessions where you sent one message or none (mostly automated `claude -p` runs); hidden by default.
    var isTrivial: Bool { firstPrompt == nil || firstUUID == nil || firstUUID == lastUUID }
    var folderName: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "?" }
}

/// Names and pins you give sessions in the All Sessions view; kept by session id.
struct HistoryMeta: Codable {
    var names: [String: String] = [:]
    var pinned: [String] = []   // in pin order
    /// Short per-session notes, by session id.
    var notes: [String: String]? = nil
}

/// Builds and caches the list of every past session. Only files whose size or mtime changed are reread,
/// and even then only their first and last few hundred KB.
enum HistoryScanner {
    static func scan(cached: [String: HistoryItem]) -> [HistoryItem] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Registry.projectsDir, includingPropertiesForKeys: nil)) ?? []
        var items: [HistoryItem] = []
        var toRead: [(URL, Date, Int)] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = values.contentModificationDate, let size = values.fileSize, size > 0 else { continue }
                if let old = cached[url.path], old.size == size, old.mtime == mtime {
                    items.append(old)
                } else {
                    toRead.append((url, mtime, size))
                }
            }
        }
        // New or changed files are read in parallel (the first scan touches ~2,000 of them).
        var fresh = [HistoryItem?](repeating: nil, count: toRead.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: toRead.count) { i in
            let (url, mtime, size) = toRead[i]
            let item = read(url, mtime: mtime, size: size)
            lock.lock(); fresh[i] = item; lock.unlock()
        }
        return items + fresh.compactMap { $0 }
    }

    static func read(_ url: URL, mtime: Date, size: Int) -> HistoryItem? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var item = HistoryItem(id: url.deletingPathExtension().lastPathComponent, path: url.path, mtime: mtime, size: size)

        // Head: folder, creation time, first prompt.
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in lines(head, dropFirst: false, dropLast: size > head.count) {
            guard let obj = json(line) else { continue }
            if item.created == nil, let ts = obj["timestamp"] as? String { item.created = TranscriptReader.parseDate(ts) }
            if item.cwd == nil, let cwd = obj["cwd"] as? String { item.cwd = cwd }
            if item.entrypoint == nil { item.entrypoint = obj["entrypoint"] as? String }
            if item.firstPrompt == nil, let p = typedPrompt(obj) { item.firstPrompt = p.text; item.firstUUID = obj["uuid"] as? String }
            if item.cwd != nil, item.firstPrompt != nil, item.created != nil { break }
        }

        // Tail, growing until we have your last prompt and a title (or reach the start).
        var window = 256 * 1024
        var customTitle: String?, aiTitle: String?
        while true {
            let start = max(0, size - window)
            try? handle.seek(toOffset: UInt64(start))
            let data = (try? handle.readToEnd()) ?? Data()
            for line in lines(data, dropFirst: start > 0, dropLast: false).reversed() {
                let isTitle = line.contains("\"custom-title\"") || line.contains("\"ai-title\"")
                let isUser = line.contains("\"type\":\"user\"")
                guard isTitle || (item.lastPrompt == nil && isUser) else { continue }
                guard let obj = json(line) else { continue }
                switch obj["type"] as? String {
                case "custom-title": if customTitle == nil { customTitle = obj["customTitle"] as? String ?? obj["title"] as? String }
                case "ai-title": if aiTitle == nil { aiTitle = obj["aiTitle"] as? String }
                case "user":
                    if item.lastPrompt == nil, let p = typedPrompt(obj) {
                        item.lastPrompt = p.text; item.lastUserAt = p.at; item.lastUUID = obj["uuid"] as? String
                    }
                default: break
                }
                if customTitle != nil, item.lastPrompt != nil { break }
            }
            // Stop at the start of the file, or once we have your last prompt and either a title or 4 MB read.
            let cap = 4 * 1024 * 1024
            let done = start == 0 || (item.lastPrompt != nil && (customTitle != nil || aiTitle != nil || window >= cap))
            if done { break }
            // Without your last prompt keep going to the start; otherwise stop growing at the cap.
            window = item.lastPrompt == nil ? window * 8 : min(window * 4, cap)
        }
        item.title = customTitle ?? aiTitle
        if item.cwd == nil { item.cwd = decodeFolder(url.deletingLastPathComponent().lastPathComponent) }
        return item
    }

    /// A message you actually typed (not tool output, commands or system text).
    private static func typedPrompt(_ obj: [String: Any]) -> (text: String, at: Date?)? {
        guard obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = message["content"] as? String { text = s }
        if let parts = message["content"] as? [[String: Any]] {
            text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let clean = text.flatMap(PromptFilter.typedText) else { return nil }
        return (clean, (obj["timestamp"] as? String).flatMap(TranscriptReader.parseDate))
    }

    private static func lines(_ data: Data, dropFirst: Bool, dropLast: Bool) -> [Substring] {
        let text = String(decoding: data, as: UTF8.self)
        var result = text.split(separator: "\n")
        if dropFirst, !result.isEmpty { result.removeFirst() }
        if dropLast, !result.isEmpty { result.removeLast() }
        return result
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// Best effort when a transcript has no cwd: "-Users-me-code-app" → "/Users/me/code/app".
    private static func decodeFolder(_ encoded: String) -> String? {
        encoded.hasPrefix("-") ? encoded.replacingOccurrences(of: "-", with: "/") : nil
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var meta = HistoryMeta()

    private var scanTask: Task<Void, Never>?
    /// Called on the main actor after each scan.
    var onRefreshed: (([HistoryItem]) -> Void)?
    private let dir = DeckStore.stateURL.deletingLastPathComponent()
    // Bump the file name when HistoryItem gains fields, so old caches are rebuilt.
    private var indexURL: URL { dir.appendingPathComponent("history-index-v3.json") }
    private var metaURL: URL { dir.appendingPathComponent("history.json") }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: metaURL), let m = try? decoder.decode(HistoryMeta.self, from: data) { meta = m }
        if let data = try? Data(contentsOf: indexURL), let cached = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = cached
        }
    }

    /// Rescan in the background; cheap after the first time.
    func refresh() {
        guard scanTask == nil else { return }
        scanning = true
        let cached = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let indexURL = indexURL
        scanTask = Task.detached(priority: .utility) {
            let fresh = HistoryScanner.scan(cached: cached)
            if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: indexURL, options: .atomic) }
            await MainActor.run {
                self.items = fresh
                self.onRefreshed?(fresh)
                self.scanning = false
                self.scanTask = nil
            }
        }
    }

    func isPinned(_ id: String) -> Bool { meta.pinned.contains(id) }

    func togglePin(_ id: String) {
        if let i = meta.pinned.firstIndex(of: id) { meta.pinned.remove(at: i) } else { meta.pinned.append(id) }
        saveMeta()
    }

    func movePinned(from offsets: IndexSet, to destination: Int, visible: [String]) {
        var order = visible
        order.move(fromOffsets: offsets, toOffset: destination)
        meta.pinned = order + meta.pinned.filter { !visible.contains($0) }
        saveMeta()
    }

    func note(_ id: String?) -> String? { id.flatMap { meta.notes?[$0] } }

    func setNote(_ id: String, _ note: String?) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        var notes = meta.notes ?? [:]
        notes[id] = (trimmed?.isEmpty ?? true) ? nil : trimmed
        meta.notes = notes
        saveMeta()
    }

    func name(_ id: String) -> String? { meta.names[id] }

    func setName(_ id: String, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        meta.names[id] = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveMeta()
    }

    private func saveMeta() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) { try? data.write(to: metaURL, options: .atomic) }
    }
}
