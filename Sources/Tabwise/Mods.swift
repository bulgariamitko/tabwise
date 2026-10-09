import Foundation

/// Claude Code mods (plugin folders) shipped inside the app and loaded into every session Tabwise starts,
/// via --plugin-dir. Each mod is on unless you switch it off, including mods added in later releases.
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

    private static let lock = NSLock()
    private static var lastFound: [Mod]?

    /// Every folder holding .claude-plugin/plugin.json, by name. The folder may be in Dropbox or another cloud
    /// folder whose reads can stall, so this waits at most a second and otherwise uses the last list it read.
    static func available() -> [Mod] {
        if let found = Bounded.run(timeout: 1, fallback: nil, { Optional(scan()) }) { remember(found); return found }
        lock.lock(); defer { lock.unlock() }
        return lastFound ?? []
    }

    /// Reads the mods in the background (at launch), so the first session has them without waiting.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { remember(scan()) }
    }

    private static func remember(_ mods: [Mod]) { lock.lock(); lastFound = mods; lock.unlock() }

    private static func scan() -> [Mod] {
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

    /// Enabled mods' folders, minus mods Claude Code already loads from CLAUDE_CODE_PLUGIN_DIRS in your
    /// settings.json env, so none loads twice.
    static func toLoad() -> [String] {
        var dirs = ""
        let settings = Registry.claudeDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = json["env"] as? [String: Any], let value = env["CLAUDE_CODE_PLUGIN_DIRS"] as? String {
            dirs += ":" + value
        }
        let paths = dirs.split(separator: ":").map(String.init)
        let loaded = Set(Bounded.run(timeout: 1, fallback: paths.map { ($0 as NSString).lastPathComponent }) {
            paths.map(pluginName(at:))
        })
        return enabled.filter { !loaded.contains($0.name) }.map(\.path)
    }

    private static func pluginName(at dir: String) -> String {
        let path = (dir as NSString).expandingTildeInPath
        let manifest = URL(fileURLWithPath: path).appendingPathComponent(".claude-plugin/plugin.json")
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String {
            return name
        }
        return (path as NSString).lastPathComponent
    }
}
