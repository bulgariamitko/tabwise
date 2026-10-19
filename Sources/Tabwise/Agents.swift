import Foundation
import Darwin
import SwiftTerm

/// The coding agent a tab runs. Claude Code reports its own state (~/.claude/sessions); Codex and Antigravity don't,
/// so Tabwise finds their process, reads their screen for working / needs-you, and their session files for resume.
enum Agent: String, Codable, CaseIterable, Identifiable {
    case claude, codex, antigravity
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    /// Start command for a non-Claude agent: resume `sessionId` if it has a saved conversation, or the folder's
    /// latest one with `continueLatest`.
    func startCommand(sessionId: String?, cwd: String, continueLatest: Bool) -> String {
        let q = ResumeCommand.shellQuote
        // When the disk doesn't answer in time, try to resume anyway (the agent says so if it can't).
        let saved = sessionId.flatMap { id in
            Bounded.run(timeout: 1, fallback: true) { AgentSessions.exists(self, sessionId: id, cwd: cwd) } ? id : nil
        }
        switch self {
        case .claude: return "claude" // built in SessionTab.start (flags, status line, mods)
        case .codex:
            if let saved { return "codex resume \(q(saved))" }
            return continueLatest ? "codex resume --last" : "codex"
        case .antigravity:
            if let saved { return "agy --conversation \(q(saved))" }
            return continueLatest ? "agy --continue" : "agy"
        }
    }
}

/// Finds an agent's process inside a tab's shell.
enum AgentProcess {
    struct Proc { let pid: pid_t; let ppid: pid_t; let comm: String }

    /// Every process on the machine (one sysctl call).
    static func all() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8 // room for processes started in between
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map { p in
            var comm = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Proc(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, comm: name)
        }
    }

    /// The agent's pid among the descendants of `shell`, if it's running.
    static func find(_ agent: Agent, under shell: pid_t, in procs: [Proc]) -> pid_t? {
        var children: [pid_t: [Proc]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        var queue = children[shell] ?? []
        var seen = 0
        while !queue.isEmpty, seen < 200 {
            let p = queue.removeFirst()
            seen += 1
            if matches(agent, p) { return p.pid }
            queue += children[p.pid] ?? []
        }
        return nil
    }

    private static func matches(_ agent: Agent, _ p: Proc) -> Bool {
        switch agent {
        case .claude: return p.comm == "claude"
        case .codex: return p.comm == "codex"
        case .antigravity: return p.comm == "agy"
        }
    }
}

/// Working / needs-you, read off the screen of an agent that doesn't report its state.
enum AgentScreen {
    /// Screen rows down to the last one with text (until the screen fills up, the rest below is blank).
    static func lines(_ t: Terminal) -> [String] {
        var screen = (0..<t.rows).compactMap { r -> String? in
            guard let line = t.getLine(row: r) else { return nil }
            return String((0..<min(line.count, t.cols)).map { c -> Character in
                let ch = t.getCharacter(for: line[c])
                return ch == "\u{0}" ? " " : ch
            })
        }
        while let last = screen.last, last.allSatisfy(\.isWhitespace) { screen.removeLast() }
        return screen
    }

    static func status(_ agent: Agent, terminal t: Terminal, title: String?) -> TabStatus {
        // The prompts and spinners sit at the bottom; old output above may quote the same words.
        let bottom = lines(t).suffix(18).joined(separator: "\n").lowercased()
        switch agent {
        case .claude:
            return .idle
        case .codex:
            if bottom.contains("would you like to") || bottom.contains("yes, proceed") || bottom.contains("to navigate questions") {
                return .waiting
            }
            // Codex puts a braille spinner in the window title while it works ("⠸ | folder").
            if let first = title?.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) { return .working }
            return bottom.contains("esc to interrupt") ? .working : .idle
        case .antigravity:
            // Its questions: "Requesting permission for: … Run this command?", "Accept this file edit?",
            // "Allow access to this file?" and the like, and the sign-in / trust-this-folder screens.
            let asks = ["requesting permission for", "run this command?", "accept this file edit?", "allow access to this",
                        "allow calling this tool?", "allow creation of this file?", "allow sandbox bypass",
                        "allow administrator elevation?", "allow remote debugging?", "trust this folder?",
                        "do you trust the contents", "select login method", "import this conversation?"]
            if asks.contains(where: bottom.contains) { return .waiting }
            // "⡿  Generating..." / "Running command..." above the box, "esc to cancel" below it while it works.
            return bottom.contains("esc to cancel") ? .working : .idle
        }
    }
}

/// Codex and Antigravity conversations on disk: which one a tab is in, whether it can be resumed, title and preview.
enum AgentSessions {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let codexSessions = home.appendingPathComponent(".codex/sessions")
    static let codexIndex = home.appendingPathComponent(".codex/session_index.jsonl")
    static let agyData = home.appendingPathComponent(".gemini/antigravity-cli")

    static func exists(_ agent: Agent, sessionId: String, cwd: String) -> Bool {
        switch agent {
        case .claude: return Registry.transcriptExists(sessionId)
        case .codex, .antigravity: return file(agent, sessionId: sessionId, cwd: cwd) != nil
        }
    }

    /// The conversation an agent started in `cwd` since `since` (or resumed: its file was written since then),
    /// leaving out ones other tabs already own. Newest first.
    static func discover(_ agent: Agent, cwd: String, since: Date, excluding taken: Set<String>) -> String? {
        let candidates: [(id: String, cwd: String?, mtime: Date)]
        switch agent {
        case .claude: return nil
        case .codex:
            candidates = recentFiles(in: codexDayDirs(), ext: "jsonl", since: since).compactMap { url, mtime in
                guard let meta = codexMeta(url) else { return nil }
                return (meta.id, meta.cwd, mtime)
            }
        case .antigravity:
            // Antigravity notes each folder's latest conversation; a tab's is that one once it has written since.
            guard let id = agyLastConversation(cwd: cwd), let url = file(agent, sessionId: id, cwd: cwd),
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mtime >= since else { return nil }
            candidates = [(id, nil, mtime)]
        }
        let folder = canonical(cwd)
        return candidates
            .filter { !taken.contains($0.id) && ($0.cwd == nil || canonical($0.cwd!) == folder) }
            .max { $0.mtime < $1.mtime }?.id
    }

    static func file(_ agent: Agent, sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        switch agent {
        case .claude: return nil
        case .codex:
            // rollout-<time>-<id>.jsonl, in a folder per day; look at recent days first.
            for dir in codexDayDirs(all: true) {
                if let name = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasSuffix("\(sessionId).jsonl") }) {
                    return dir.appendingPathComponent(name)
                }
            }
            return nil
        case .antigravity:
            let url = agyTranscript(sessionId)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Title (Codex's thread name, else your first message), last message and when you last wrote.
    static func read(_ agent: Agent, url: URL, sessionId: String) -> TranscriptInfo {
        var info = TranscriptInfo()
        switch agent {
        case .claude: break
        case .codex:
            // Rollouts grow to many MB: your first message is near the top, the latest ones at the end.
            func messages(_ lines: [Substring]) -> [(role: String, text: String, at: Date?)] {
                lines.compactMap { line in
                    guard line.contains("\"response_item\""),
                          let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any], payload["type"] as? String == "message",
                          let role = payload["role"] as? String, role == "user" || role == "assistant" else { return nil }
                    let parts = payload["content"] as? [[String: Any]] ?? []
                    let raw = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                    // Codex sends its own context as user messages too; those start with a tag.
                    guard !(role == "user" && raw.hasPrefix("<")), let text = PromptFilter.typedText(raw) else { return nil }
                    return (role, text, (obj["timestamp"] as? String).flatMap(TranscriptReader.parseDate))
                }
            }
            let firstPrompt = messages(lines(url, head: 256 * 1024)).first { $0.role == "user" }?.text
            let recent = messages(lines(url, tail: 1024 * 1024))
            if let last = recent.last { info.preview = last.text; info.previewIsUser = last.role == "user" }
            info.lastUserAt = recent.last { $0.role == "user" }?.at
            info.title = codexThreadName(sessionId) ?? firstPrompt
        case .antigravity:
            // One line per step: USER_INPUT (your message, wrapped in <USER_REQUEST>), PLANNER_RESPONSE (its replies
            // and tool calls), and tool results. Long conversations grow large; the start and end are enough.
            func messages(_ lines: [Substring]) -> [(user: Bool, text: String, at: Date?)] {
                lines.compactMap { line in
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let type = obj["type"] as? String, type == "USER_INPUT" || type == "PLANNER_RESPONSE",
                          var raw = obj["content"] as? String else { return nil }
                    let user = type == "USER_INPUT"
                    if user {
                        guard obj["source"] as? String == "USER_EXPLICIT" else { return nil }
                        if let a = raw.range(of: "<USER_REQUEST>"), let b = raw.range(of: "</USER_REQUEST>"), a.upperBound <= b.lowerBound {
                            raw = String(raw[a.upperBound..<b.lowerBound])
                        }
                    }
                    guard let text = PromptFilter.typedText(raw) else { return nil }
                    return (user, text, (obj["created_at"] as? String).flatMap(TranscriptReader.parseDate))
                }
            }
            let firstPrompt = messages(lines(url, head: 256 * 1024)).first { $0.user }?.text
            let recent = messages(lines(url, tail: 1024 * 1024))
            if let last = recent.last { info.preview = last.text; info.previewIsUser = last.user }
            info.lastUserAt = recent.last { $0.user }?.at
            info.title = agyTitle(sessionId) ?? firstPrompt
        }
        return info
    }

    // MARK: Codex

    /// Day folders (…/sessions/YYYY/MM/DD), newest first: the last three days, or all of them.
    private static func codexDayDirs(all: Bool = false) -> [URL] {
        let fm = FileManager.default
        if !all {
            let cal = Calendar(identifier: .gregorian)
            return (0..<3).compactMap { back -> URL? in
                guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                return codexSessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            }
        }
        func sub(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.allSatisfy(\.isNumber) }.sorted(by: >)
                .map { url.appendingPathComponent($0) }
        }
        return sub(codexSessions).flatMap(sub).flatMap(sub)
    }

    private static func codexMeta(_ url: URL) -> (id: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "session_meta", let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    /// The name Codex gave the conversation (the latest entry for it in session_index.jsonl).
    private static func codexThreadName(_ sessionId: String) -> String? {
        guard let text = try? String(contentsOf: codexIndex, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains(sessionId) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["id"] as? String == sessionId, let name = obj["thread_name"] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    // MARK: Antigravity

    private static func agyTranscript(_ id: String) -> URL {
        agyData.appendingPathComponent("brain").appendingPathComponent(id)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    /// cache/last_conversations.json: {folder: its latest conversation}.
    private static func agyLastConversation(cwd: String) -> String? {
        guard let data = try? Data(contentsOf: agyData.appendingPathComponent("cache/last_conversations.json")),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return map[cwd] ?? map[canonical(cwd)]
    }

    /// The conversation's title or summary, once Antigravity has written one (cache/conversation_metadata.json).
    private static func agyTitle(_ id: String) -> String? {
        guard let data = try? Data(contentsOf: agyData.appendingPathComponent("cache/conversation_metadata.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = ((obj["conversations"] as? [String: Any])?[id] as? [String: Any])?["summary"] as? [String: Any]
        else { return nil }
        for key in ["Title", "Preview"] {
            if let s = summary[key] as? String, let text = PromptFilter.typedText(s) { return text }
        }
        return nil
    }

    // MARK: Helpers

    private static func recentFiles(in dirs: [URL], ext: String, since: Date) -> [(URL, Date)] {
        let fm = FileManager.default
        return dirs.flatMap { dir -> [(URL, Date)] in
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return urls.compactMap { url in
                guard url.pathExtension == ext,
                      let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime >= since else { return nil }
                return (url, mtime)
            }
        }
    }

    private static func lines(_ url: URL, head: Int? = nil, tail: Int? = nil) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var data: Data
        var cut = false
        if let tail {
            let end = (try? handle.seekToEnd()) ?? 0
            let start = end > UInt64(tail) ? end - UInt64(tail) : 0
            try? handle.seek(toOffset: start)
            cut = start > 0
            data = (try? handle.readToEnd()) ?? Data()
        } else {
            data = (try? handle.read(upToCount: head ?? Int.max)) ?? Data()
        }
        var result = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if cut, !result.isEmpty { result.removeFirst() } // partial line
        return result
    }

    static func canonical(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}
