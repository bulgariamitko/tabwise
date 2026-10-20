import Foundation

/// Gives Codex and Antigravity tabs the MCP servers Claude Code has for that folder (`claude mcp add`, user and
/// local scope, and a project's .mcp.json once you've approved it in Claude). claude.ai connectors (Gmail, Drive…)
/// sign in through your Claude account, so they can't be shared.
///
/// Codex gets them as `-c mcp_servers.…` flags on its command line, so its config.toml isn't touched; secrets
/// (env values, headers) go through the tab's environment instead of the command line. Antigravity has no such
/// flag, so they're written to its mcp_config.json, and the ones Tabwise wrote are removed again when Claude no
/// longer has them. A server you added to Antigravity yourself is never changed.
enum MCPShare {
    struct Server: Equatable {
        var name: String
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]
        var url: String?
        var headers: [String: String] = [:]
    }

    /// Settings → Share Claude's MCP servers; on by default.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "shareMCP") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shareMCP") }
    }

    // MARK: Claude's servers

    /// Claude's servers for `cwd`, as Claude itself would load them there: local scope over project over user.
    static func claudeServers(cwd: String) -> [Server] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let data = FileManager.default.contents(atPath: home + "/.claude.json"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let projects = root["projects"] as? [String: Any] ?? [:]
        let canonical = (cwd as NSString).resolvingSymlinksInPath
        let project = (projects[cwd] ?? projects[canonical]) as? [String: Any] ?? [:]

        var byName: [String: [String: Any]] = [:]
        for (name, value) in root["mcpServers"] as? [String: Any] ?? [:] { byName[name] = value as? [String: Any] }
        // A project's .mcp.json counts only after you approved it in Claude (it can run any command).
        let mcpJSON = (cwd as NSString).appendingPathComponent(".mcp.json")
        if let data = Bounded.run(timeout: 0.5, fallback: nil, { FileManager.default.contents(atPath: mcpJSON) }),
           let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let all = project["enableAllProjectMcpServers"] as? Bool ?? false
            let enabled = Set(project["enabledMcpjsonServers"] as? [String] ?? [])
            let disabled = Set(project["disabledMcpjsonServers"] as? [String] ?? [])
            for (name, value) in file["mcpServers"] as? [String: Any] ?? [:]
            where (all || enabled.contains(name)) && !disabled.contains(name) {
                byName[name] = value as? [String: Any]
            }
        }
        for (name, value) in project["mcpServers"] as? [String: Any] ?? [:] { byName[name] = value as? [String: Any] }
        let off = Set(project["disabledMcpServers"] as? [String] ?? [])

        return byName.keys.sorted().compactMap { name in
            guard !off.contains(name), let config = byName[name] else { return nil }
            return server(name, config)
        }
    }

    private static func server(_ name: String, _ c: [String: Any]) -> Server? {
        let type = c["type"] as? String ?? (c["url"] != nil ? "http" : "stdio")
        var s = Server(name: name)
        switch type {
        case "stdio":
            guard let command = c["command"] as? String else { return nil }
            s.command = expand(command)
            s.args = (c["args"] as? [Any] ?? []).compactMap { $0 as? String }.map(expand)
            for (k, v) in c["env"] as? [String: Any] ?? [:] { if let v = v as? String { s.env[k] = expand(v) } }
        case "http":
            guard let url = c["url"] as? String else { return nil }
            s.url = expand(url)
            for (k, v) in c["headers"] as? [String: Any] ?? [:] { if let v = v as? String { s.headers[k] = expand(v) } }
        default:
            return nil // SSE: neither Codex nor Antigravity speaks it
        }
        return s
    }

    /// Claude's `${VAR}` and `${VAR:-default}` in server settings, from Tabwise's environment.
    static func expand(_ s: String) -> String {
        guard s.contains("${") else { return s }
        let env = ProcessInfo.processInfo.environment
        var out = "", rest = Substring(s)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]
            let body = rest[open.upperBound..<close]
            if let dash = body.range(of: ":-") {
                out += env[String(body[..<dash.lowerBound])] ?? String(body[dash.upperBound...])
            } else {
                out += env[String(body)] ?? ""
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: Codex

    /// `-c` flags for `codex`, and the environment variables they read their secrets from.
    static func codexFlags(_ servers: [Server]) -> (args: [String], env: [String: String]) {
        var args: [String] = [], env: [String: String] = [:]
        for (i, s) in servers.enumerated() {
            var fields: [String] = []
            if let command = s.command {
                fields.append("command=\(toml(command))")
                if !s.args.isEmpty { fields.append("args=[\(s.args.map(toml).joined(separator: ","))]") }
                // Codex hands a server only the variables named here; the values ride in the tab's environment.
                var forwarded: [String] = [], inline: [String] = []
                for (k, v) in s.env.sorted(by: { $0.key < $1.key }) {
                    if env[k] == nil || env[k] == v { env[k] = v; forwarded.append(k) }
                    else { inline.append("\(toml(k))=\(toml(v))") } // another server needs a different value
                }
                if !forwarded.isEmpty { fields.append("env_vars=[\(forwarded.map(toml).joined(separator: ","))]") }
                if !inline.isEmpty { fields.append("env={\(inline.joined(separator: ","))}") }
            } else if let url = s.url {
                fields.append("url=\(toml(url))")
                var headers: [String] = []
                for (j, (k, v)) in s.headers.sorted(by: { $0.key < $1.key }).enumerated() {
                    let variable = "TABWISE_MCP_\(i)_HEADER_\(j)"
                    env[variable] = v
                    headers.append("\(toml(k))=\(toml(variable))")
                }
                if !headers.isEmpty { fields.append("env_http_headers={\(headers.joined(separator: ","))}") }
            }
            args += ["-c", "mcp_servers.\(key(s.name))={\(fields.joined(separator: ","))}"]
        }
        return (args, env)
    }

    /// Codex splits `-c` paths on dots, so a server name keeps to letters, digits, - and _.
    private static func key(_ name: String) -> String {
        String(name.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func toml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Antigravity

    static var antigravityConfig: URL {
        if let path = ProcessInfo.processInfo.environment["TABWISE_AGY_MCP_CONFIG"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/mcp_config.json")
    }

    /// Names Tabwise wrote into Antigravity's config, so it only ever updates or removes its own.
    @MainActor private static var managedURL: URL {
        DeckStore.stateURL.deletingLastPathComponent().appendingPathComponent("antigravity-mcp.json")
    }

    /// Makes Antigravity's config hold `servers` (plus whatever you added there yourself). Antigravity reads it
    /// when it starts, so this runs right before an Antigravity tab starts.
    @MainActor static func syncAntigravity(_ servers: [Server]) {
        let url = antigravityConfig
        let managed = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: managedURL))) ?? [])
        if servers.isEmpty && managed.isEmpty { return }
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            // Unreadable config: leave it alone rather than overwrite what's there.
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            root = parsed
        }
        var config = root["mcpServers"] as? [String: Any] ?? [:]
        var nowManaged: [String] = []

        for name in managed where !servers.contains(where: { $0.name == name }) { config[name] = nil }
        for s in servers {
            if config[s.name] != nil && !managed.contains(s.name) { continue } // yours
            var entry: [String: Any] = ["disabled": false]
            if let command = s.command {
                entry["command"] = command
                if !s.args.isEmpty { entry["args"] = s.args }
                if !s.env.isEmpty { entry["env"] = s.env }
            } else if let url = s.url {
                entry["serverUrl"] = url
                if !s.headers.isEmpty { entry["headers"] = s.headers }
            }
            config[s.name] = entry
            nowManaged.append(s.name)
        }

        root["mcpServers"] = config
        let before = try? Data(contentsOf: url)
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        if data != before {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            // It can hold passwords and tokens now.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let list = try? JSONEncoder().encode(nowManaged.sorted()) { try? list.write(to: managedURL, options: .atomic) }
    }
}
