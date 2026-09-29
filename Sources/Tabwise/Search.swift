import Foundation

/// Searches the full text of conversations (not just names and prompts) and returns a snippet per match.
/// Works on raw UTF-8 bytes with its own case folding for Latin and Cyrillic, which is far faster on
/// gigabytes of transcripts than String's case-insensitive search.
enum FullTextSearch {
    static func search(_ query: String, in files: [(id: String, path: String)]) -> [String: String] {
        let needle = fold(Array(query.trimmingCharacters(in: .whitespaces).utf8))
        guard needle.count >= 3 else { return [:] }
        var results = [String?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if Task.isCancelled { return }
            guard let data = FileManager.default.contents(atPath: files[i].path) else { return }
            let bytes = [UInt8](data)
            let hay = fold(bytes)
            guard let at = find(needle, in: hay) else { return }
            let snip = snippet(bytes, at: at, length: needle.count)
            lock.lock(); results[i] = snip; lock.unlock()
        }
        var out: [String: String] = [:]
        for (i, f) in files.enumerated() { if let s = results[i] { out[f.id] = s } }
        return out
    }

    /// Lowercases ASCII and Cyrillic (А–Я, Ѐ–Џ) in place; UTF-8 lengths don't change.
    static func fold(_ input: [UInt8]) -> [UInt8] {
        var b = input
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c >= 0x41 && c <= 0x5A { b[i] = c | 0x20 }
            else if c == 0xD0, i + 1 < n {
                let d = b[i + 1]
                if d >= 0x90 && d <= 0x9F { b[i + 1] = d + 0x20 }              // А–П → а–п
                else if d >= 0xA0 && d <= 0xAF { b[i] = 0xD1; b[i + 1] = d - 0x20 } // Р–Я → р–я
                else if d >= 0x80 && d <= 0x8F { b[i] = 0xD1; b[i + 1] = d + 0x10 } // Ѐ–Џ → ѐ–џ
                i += 1
            }
            i += 1
        }
        return b
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { nd in
                guard let p = memmem(h.baseAddress, h.count, nd.baseAddress, nd.count) else { return nil }
                return h.baseAddress!.distance(to: p)
            }
        }
    }

    /// ~140 bytes around the match (on character boundaries), with JSON escapes turned into spaces.
    private static func snippet(_ bytes: [UInt8], at: Int, length: Int) -> String {
        var start = max(0, at - 70)
        var end = min(bytes.count, at + length + 90)
        while start > 0 && bytes[start] & 0xC0 == 0x80 { start -= 1 }
        while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end += 1 }
        var s = String(decoding: bytes[start..<end], as: UTF8.self)
        for esc in ["\\n", "\\t", "\\\"", "\\r"] { s = s.replacingOccurrences(of: esc, with: " ") }
        s = s.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "{" || $0 == "}" }).joined(separator: " ")
        return "…" + s + "…"
    }
}
