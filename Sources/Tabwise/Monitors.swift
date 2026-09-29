import Foundation
import Darwin

/// Branch and working-tree state of a session's folder.
struct GitInfo: Equatable {
    var branch: String
    var changed: Int
    var ahead: Int
    var behind: Int

    var label: String {
        var parts = [branch]
        if changed > 0 { parts.append("±\(changed)") }
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }

    /// `git status --porcelain -b` for a folder, or nil if it isn't a repository.
    static func read(_ cwd: String) -> GitInfo? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "--no-optional-locks", "status", "--porcelain=v1", "-b", "--untracked-files=normal"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let head = lines.first, head.hasPrefix("## ") else { return nil }
        // "## main...origin/main [ahead 1, behind 2]" or "## No commits yet on main" or "## HEAD (no branch)"
        var header = head.dropFirst(3)
        if header.hasPrefix("No commits yet on ") { header = header.dropFirst("No commits yet on ".count) }
        let token = header.split(separator: " ").first.map(String.init) ?? "?"
        let branch = token.components(separatedBy: "...").first ?? token
        func count(_ key: String) -> Int {
            guard let r = header.range(of: key + " ") else { return 0 }
            return Int(header[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        return GitInfo(branch: branch, changed: lines.count - 1,
                       ahead: count("ahead"), behind: count("behind"))
    }
}

enum ProcessMemory {
    /// Memory in use by a process and all its children (what Activity Monitor calls "Memory").
    static func footprint(ofTree pid: pid_t) -> UInt64 {
        var total: UInt64 = 0
        var queue = [pid]
        var seen = Set<pid_t>()
        while let p = queue.popLast(), seen.insert(p).inserted, seen.count < 64 {
            total += footprint(p)
            queue += children(of: p)
        }
        return total
    }

    private static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : 0
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(buffer.prefix(Int(n))).filter { $0 > 0 } : []
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
