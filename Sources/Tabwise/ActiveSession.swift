import AppKit

/// Publishes which Claude session you're looking at to ~/.claude/tabwise/active.json, so other tools
/// (e.g. a Claude Code mod that reads replies aloud) can act only for the tab in front of you.
@MainActor
enum ActiveSession {
    static let url: URL = {
        // A test copy (TABWISE_STATE_DIR) writes next to its own state instead of the real file.
        let dir = ProcessInfo.processInfo.environment["TABWISE_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? Registry.claudeDir.appendingPathComponent("tabwise")
        return dir.appendingPathComponent("active.json")
    }()

    private struct State: Encodable, Equatable {
        var sessionId: String?
        var visibleSessionIds: [String]
        var isAppActive: Bool
        var pid: Int32
        var updatedAt: Int64

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sessionId, forKey: .sessionId) // written as null, not left out
            try c.encode(visibleSessionIds, forKey: .visibleSessionIds)
            try c.encode(isAppActive, forKey: .isAppActive)
            try c.encode(pid, forKey: .pid)
            try c.encode(updatedAt, forKey: .updatedAt)
        }
        private enum CodingKeys: String, CodingKey { case sessionId, visibleSessionIds, isAppActive, pid, updatedAt }
    }

    private static var last: State?

    /// Cheap to call often: writes only when something changed.
    static func publish(_ store: DeckStore, quitting: Bool = false) {
        let visible = [store.selected, store.splitID == store.selectedID ? nil : store.tabs.first { $0.id == store.splitID }]
            .compactMap { $0 }.filter { !$0.archived }
        // The tab selected in the sidebar (in split view, the other half is only in visibleSessionIds).
        let focused = visible.first { $0.id == store.selectedID }
        func claudeId(_ tab: SessionTab?) -> String? { tab?.isClaude == true ? tab?.sessionId : nil }
        var state = State(sessionId: quitting ? nil : claudeId(focused),
                          visibleSessionIds: quitting ? [] : visible.compactMap(claudeId),
                          isAppActive: quitting ? false : NSApp.isActive,
                          pid: ProcessInfo.processInfo.processIdentifier, updatedAt: 0)
        if var previous = last {
            previous.updatedAt = 0
            if previous == state { return }
        }
        state.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        last = state
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic) // temp file + rename
    }
}
