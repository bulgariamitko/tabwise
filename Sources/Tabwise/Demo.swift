import Foundation

/// Screenshot mode for the README: `TABWISE_DEMO=/path/demo.json` gives tabs made-up statuses, previews,
/// times, memory and git info, so marketing screenshots never show anyone's real sessions.
/// The file maps tab ids to entries. Not used in normal runs.
struct DemoTab: Decodable {
    var status: String?          // working | waiting | idle | shell
    var preview: String?
    var previewIsUser: Bool?
    var minutesAgo: Double?
    var memoryMB: Double?
    var branch: String?
    var changed: Int?
    var attention: Bool?
}

@MainActor
enum Demo {
    static let tabs: [UUID: DemoTab]? = {
        guard let path = ProcessInfo.processInfo.environment["TABWISE_DEMO"],
              let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode([String: DemoTab].self, from: data) else { return nil }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }()

    static func apply(to tabs: [SessionTab]) {
        guard let demo = Self.tabs else { return }
        for tab in tabs {
            guard let d = demo[tab.id] else { continue }
            switch d.status {
            case "working": tab.status = .working
            case "waiting": tab.status = .waiting
            case "idle": tab.status = .idle
            case "shell": tab.status = .shell
            default: break
            }
            if let p = d.preview { tab.transcript.preview = p; tab.transcript.previewIsUser = d.previewIsUser ?? false }
            if let m = d.minutesAgo { tab.lastActive = Date().addingTimeInterval(-m * 60) }
            if let mb = d.memoryMB { tab.memory = UInt64(mb * 1_048_576) }
            if let b = d.branch { tab.git = GitInfo(branch: b, changed: d.changed ?? 0, ahead: 0, behind: 0) }
            if let a = d.attention { tab.needsAttention = a }
        }
    }
}
