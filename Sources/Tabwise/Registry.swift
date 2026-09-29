import Foundation
import Darwin

/// One running Claude Code process, as recorded by Claude itself in ~/.claude/sessions/<pid>.json.
struct RegistryEntry: Decodable, Identifiable, Hashable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?
    let kind: String?
    let startedAt: Double?

    var id: Int32 { pid }
}

/// A session remembered by the `claude-sessions` save/restore script (may no longer be running).
struct SnapshotEntry: Decodable, Identifiable, Hashable {
    let sessionId: String
    let name: String?
    let cwd: String
    var id: String { sessionId }
}

enum Registry {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static let sessionsDir = claudeDir.appendingPathComponent("sessions")
    static let projectsDir = claudeDir.appendingPathComponent("projects")
    static let snapshotFile = claudeDir.appendingPathComponent("claude-sessions/snapshots/latest.json")

    /// All live interactive Claude sessions on this machine.
    static func running() -> [RegistryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { url -> RegistryEntry? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(RegistryEntry.self, from: data),
                  entry.kind == nil || entry.kind == "interactive",
                  isAlive(entry.pid) else { return nil }
            return entry
        }
    }

    static func snapshot() -> [SnapshotEntry] {
        struct File: Decodable { let sessions: [SnapshotEntry] }
        guard let data = try? Data(contentsOf: snapshotFile),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.sessions
    }

    /// Whether Claude saved a conversation for this session (a brand-new session with no messages has none).
    static func transcriptExists(_ sessionId: String) -> Bool {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            if fm.fileExists(atPath: dir.appendingPathComponent("\(sessionId).jsonl").path) { return true }
        }
        return false
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// True if `pid` is `ancestor` or a descendant of it (within a few levels).
    static func pid(_ pid: pid_t, descendsFrom ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<5 {
            if current == ancestor { return true }
            guard let parent = parentPid(of: current), parent > 1 else { return false }
            current = parent
        }
        return false
    }

    /// Controlling terminal of a process, e.g. "/dev/ttys003".
    static func tty(of pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty, out != "??" else { return nil }
        return "/dev/" + out
    }
}

/// A pasted `claude --flags --resume <id>` command, or just an ID.
struct ResumeCommand: Equatable {
    var sessionId: String?
    /// Flags to keep, without the resume/continue/print ones.
    var args: [String] = []

    static func parse(_ input: String) -> ResumeCommand {
        var tokens = tokenize(input.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = tokens.first, first == "claude" || first.hasSuffix("/claude") { tokens.removeFirst() }
        var result = ResumeCommand()
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "--resume", "-r", "--session-id":
                if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") { result.sessionId = tokens[i + 1]; i += 1 }
            case "--continue", "-c", "--print", "-p":
                break
            default:
                if t.hasPrefix("--resume=") { result.sessionId = String(t.dropFirst(9)) }
                else if t.hasPrefix("-") { result.args.append(t) }
                else if result.args.last?.hasPrefix("-") == true && !(result.args.last!.contains("=")) && result.sessionId == nil && !looksLikeId(t) {
                    result.args.append(t) // value of the previous flag, e.g. "auto"
                } else if looksLikeId(t) && result.sessionId == nil {
                    result.sessionId = t
                } else {
                    result.args.append(t)
                }
            }
            i += 1
        }
        return result
    }

    static func looksLikeId(_ s: String) -> Bool {
        s.count >= 6 && s.allSatisfy { $0.isHexDigit || $0 == "-" } && s.contains { $0.isHexDigit }
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var inToken = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inToken = true; continue }
            if ch.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
                continue
            }
            current.append(ch)
            inToken = true
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_=./:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a saved conversation lives on disk and which folder it belongs to.
struct SessionLookup {
    let sessionId: String
    let cwd: String?
    let title: String?

    /// Accepts a full ID or a unique prefix of one.
    static func find(_ idOrPrefix: String) -> [SessionLookup] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Registry.projectsDir, includingPropertiesForKeys: nil)) ?? []
        var found: [URL] = []
        for dir in dirs {
            let exact = dir.appendingPathComponent("\(idOrPrefix).jsonl")
            if fm.fileExists(atPath: exact.path) { return [lookup(exact)] }
            if idOrPrefix.count < 36, let files = try? fm.contentsOfDirectory(atPath: dir.path) {
                found += files.filter { $0.hasPrefix(idOrPrefix) && $0.hasSuffix(".jsonl") }
                    .map { dir.appendingPathComponent($0) }
            }
        }
        return found.prefix(10).map(lookup)
    }

    private static func lookup(_ url: URL) -> SessionLookup {
        let id = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        // The cwd is recorded on the first real entries of the transcript.
        if let handle = try? FileHandle(forReadingFrom: url) {
            let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            try? handle.close()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("\"cwd\"") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let c = obj["cwd"] as? String { cwd = c; break }
            }
        }
        let title = TranscriptReader().read(sessionId: id, cwd: cwd ?? "")?.title
        return SessionLookup(sessionId: id, cwd: cwd, title: title)
    }
}

/// Decides whether a user entry is something you typed (or pasted), and cleans it up for display.
enum PromptFilter {
    /// Text Claude Code itself puts in user entries: slash-command echoes, tool errors, reminders…
    private static let systemPrefixes = [
        "<command-", "<local-command", "<system-reminder", "<task-notification", "<tool_use_error",
        "<persisted-output", "<retrieval_status", "<user-prompt-submit-hook", "<bash-", "<user-memory-input",
        "Caveat:", "[Request interrupted", "Permission granted",
        "This session is being continued from a previous conversation",
    ]

    /// Your message with paste wrappers removed and whitespace collapsed, or nil if it isn't one.
    static func typedText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !systemPrefixes.contains(where: trimmed.hasPrefix) else { return nil }
        let unwrapped = trimmed.replacingOccurrences(of: "</?pasted_content[^>]*>", with: " ", options: .regularExpression)
        let clean = unwrapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(240))
    }
}

/// Title + last-message preview pulled from a session's transcript (.jsonl).
struct TranscriptInfo: Equatable {
    var title: String?
    var preview: String?
    var previewIsUser = false
    /// Time of your most recent message in this conversation.
    var lastUserAt: Date?
}

final class TranscriptReader {
    private var paths: [String: URL] = [:]
    private var mtimes: [String: Date] = [:]
    private var cache: [String: TranscriptInfo] = [:]
    /// Sessions whose whole file was already searched: anything new is appended, so only the tail matters.
    private var searchedBack: Set<String> = []

    /// Returns nil when nothing changed since the last call.
    func read(sessionId: String, cwd: String) -> TranscriptInfo? {
        guard let url = locate(sessionId: sessionId, cwd: cwd),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if mtimes[sessionId] == mtime { return nil }
        mtimes[sessionId] = mtime
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0

        var info = cache[sessionId] ?? TranscriptInfo()
        let tail = parse(lines: readTail(url, bytes: 512 * 1024))
        if let p = tail.preview { info.preview = p; info.previewIsUser = tail.previewIsUser }
        if let t = tail.title { info.title = t }
        if let d = tail.lastUserAt { info.lastUserAt = d }
        // Title or your last message can be far back after a long tool-heavy turn: read further back
        // in growing chunks until both are found (at worst the whole file, once — a session with no
        // title at all must not re-read a 100 MB file every time it changes).
        var window = 512 * 1024
        while (info.title == nil || info.lastUserAt == nil), window < size, !searchedBack.contains(sessionId) {
            window = min(window * 8, size)
            let more = parse(lines: readTail(url, bytes: window))
            if info.title == nil { info.title = more.title }
            if info.lastUserAt == nil { info.lastUserAt = more.lastUserAt }
        }
        if window >= size || (info.title != nil && info.lastUserAt != nil) { searchedBack.insert(sessionId) }
        cache[sessionId] = info
        return info
    }

    private func locate(sessionId: String, cwd: String) -> URL? {
        if let url = paths[sessionId] { return url }
        let fm = FileManager.default
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let direct = Registry.projectsDir.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { paths[sessionId] = direct; return direct }
        let dirs = (try? fm.contentsOfDirectory(at: Registry.projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { paths[sessionId] = candidate; return candidate }
        }
        return nil
    }

    private func readTail(_ url: URL, bytes: Int) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
                ?? String(data: data.dropFirst(4), encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial line
        return lines
    }

    private func parse(lines: [Substring]) -> TranscriptInfo {
        var info = TranscriptInfo()
        var aiTitle: String?
        for line in lines.reversed() {
            if info.title != nil, info.preview != nil, info.lastUserAt != nil { break }
            // Cheap pre-filter before paying for JSON parsing.
            let isTitle = line.contains("\"custom-title\"") || line.contains("\"ai-title\"")
            let isMessage = line.hasPrefix("{\"parentUuid\"") || line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\"")
            guard isTitle || ((info.preview == nil || info.lastUserAt == nil) && isMessage) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title":
                if info.title == nil { info.title = obj["customTitle"] as? String ?? obj["title"] as? String }
            case "ai-title":
                if aiTitle == nil { aiTitle = obj["aiTitle"] as? String }
            case "assistant" where info.preview == nil:
                if let text = texts(obj).last { info.preview = text; info.previewIsUser = false }
            case "user":
                if obj["isMeta"] as? Bool == true { continue }
                // Tool results have no text parts; system text is filtered out.
                guard let text = rawTexts(obj).last.flatMap(PromptFilter.typedText) else { continue }
                if info.lastUserAt == nil, let stamp = obj["timestamp"] as? String {
                    info.lastUserAt = Self.parseDate(stamp)
                }
                if info.preview == nil { info.preview = text; info.previewIsUser = true }
            default: break
            }
        }
        if info.title == nil { info.title = aiTitle }
        return info
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private func rawTexts(_ obj: [String: Any]) -> [String] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        if let s = message["content"] as? String { return [s] }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    private func texts(_ obj: [String: Any]) -> [String] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        var result: [String] = []
        if let s = message["content"] as? String { result = [s] }
        if let parts = message["content"] as? [[String: Any]] {
            result = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        return result
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(240)) }
    }
}
