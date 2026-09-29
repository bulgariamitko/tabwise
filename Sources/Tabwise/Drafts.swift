import Foundation
import SwiftTerm

/// Reads what you've typed (but not sent) in Claude Code's input box straight off the terminal screen,
/// so it can be saved and typed back after a restart or crash.
enum DraftReader {
    /// Screen rows as (text, per-character dim/placeholder flags).
    private static func rows(_ t: Terminal) -> [(text: [Character], faint: [Bool])] {
        (0..<t.rows).map { r in
            guard let line = t.getLine(row: r) else { return ([], []) }
            var chars: [Character] = [], faint: [Bool] = []
            for c in 0..<min(line.count, t.cols) {
                let cd = line[c]
                let ch = t.getCharacter(for: cd)
                chars.append(ch == "\u{0}" ? " " : ch) // empty cells
                faint.append(isFaint(cd.attribute))
            }
            return (chars, faint)
        }
    }

    /// Placeholder hints are drawn dim or in grey.
    private static func isFaint(_ a: Attribute) -> Bool {
        if a.style.contains(.dim) { return true }
        switch a.fg {
        case .ansi256(let code): return code == 8 || code == 242 || code == 244 || code == 245 || code == 246 || (232...250).contains(code)
        case .trueColor(let r, let g, let b):
            let spread = max(r, g, b) - min(r, g, b)
            return spread < 16 && Int(r) < 170 // grey, not white
        default: return false
        }
    }

    private static func isRule(_ chars: [Character]) -> Bool {
        let s = chars.filter { $0 != " " }
        return s.count > 10 && s.allSatisfy { $0 == "─" || $0 == "━" || $0 == "╌" }
    }

    /// The unsent text in the input box, "" when it's empty, nil when no input box is on screen.
    static func read(_ terminal: Terminal) -> String? {
        let screen = rows(terminal)
        // Input box: a rule line, then "❯ text…", continuation lines, then another rule line.
        guard let bottom = screen.indices.reversed().first(where: { i in
            isRule(screen[i].text) && i > 1 && screen[..<i].contains(where: { isRule($0.text) })
        }) else { return nil }
        guard let top = screen.indices[..<bottom].reversed().first(where: { isRule(screen[$0].text) }), bottom - top >= 2
        else { return nil }
        var lines: [String] = []
        var widths: [Int] = []
        for i in (top + 1)..<bottom {
            let (chars, faint) = screen[i]
            var start = 0
            if i == top + 1 {
                guard let p = chars.firstIndex(where: { $0 != " " }), chars[p] == "❯" || chars[p] == ">" else { return nil }
                start = p + 1
            } else {
                start = min(2, chars.count)
            }
            var text = ""
            for j in start..<chars.count where !faint[j] { text.append(chars[j]) }
            lines.append(text)
            widths.append(chars.count)
        }
        // Rejoin Claude's visual wrapping: a nearly full line continues on the next one.
        var out = ""
        for (k, raw) in lines.enumerated() {
            let line = k == 0 ? raw.trimmingCharacters(in: .whitespaces) : raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if k == 0 { out = line; continue }
            let prev = lines[k - 1].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let soft = prev.count >= widths[k - 1] - 14
            out += soft ? " " + line.trimmingCharacters(in: .whitespaces) : "\n" + line
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debug aid: the bottom of the screen with faint characters marked, written when TABWISE_DEBUG_DRAFTS is set.
    static func dump(_ terminal: Terminal) -> String {
        rows(terminal).suffix(14).map { row in
            String(row.text) + "\n" + String(row.faint.map { $0 ? "·" : " " })
        }.joined(separator: "\n")
    }
}
