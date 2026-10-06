import Foundation

/// Claude Code mods (plugin folders) shipped inside the app and loaded into every session Tabwise starts,
/// via CLAUDE_CODE_PLUGIN_DIRS. Each mod is on unless you switch it off, including mods added in later releases.
enum Mods {
    struct Mod: Identifiable, Hashable {
        let name: String
        let description: String
        let path: String
        var id: String { name }
    }

    /// Dev option: load mods from a folder (e.g. their source) instead of the copies inside the app.
    static var devFolder: String? {
        get { UserDefaults.standard.string(forKey: "mods.devFolder").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "mods.devFolder") }
    }

    static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("mods") }

    static var folder: URL? { devFolder.map { URL(fileURLWithPath: $0) } ?? bundledFolder }

    /// Every folder holding .claude-plugin/plugin.json, by name.
    static func available() -> [Mod] {
        guard let folder, let dirs = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return dirs.compactMap { dir -> Mod? in
            let manifest = dir.appendingPathComponent(".claude-plugin/plugin.json")
            guard let data = try? Data(contentsOf: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let name = json["name"] as? String ?? dir.lastPathComponent
            return Mod(name: name, description: json["description"] as? String ?? "", path: dir.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Names you switched off; anything not listed is on.
    static var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mods.disabled") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "mods.disabled") }
    }

    static func isEnabled(_ name: String) -> Bool { !disabled.contains(name) }

    static func setEnabled(_ name: String, _ on: Bool) {
        var d = disabled
        if on { d.remove(name) } else { d.insert(name) }
        disabled = d
    }

    static var enabled: [Mod] { available().filter { isEnabled($0.name) } }

    /// The "statusline" mod replaces Tabwise's built-in status line while it's on.
    static var replacesStatusLine: Bool { enabled.contains { $0.name == "statusline" } }
}
