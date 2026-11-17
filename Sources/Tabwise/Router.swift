import Foundation

/// How demanding a job is. Each agent maps a tier to a model and an effort (Settings → Model Router).
enum Tier: String, Codable, CaseIterable, Identifiable, Comparable {
    case simple, everyday, complex
    var id: String { rawValue }

    var name: String {
        switch self {
        case .simple: "Simple"
        case .everyday: "Everyday"
        case .complex: "Complex"
        }
    }

    var hint: String {
        switch self {
        case .simple: "Questions, commits, renames, small edits"
        case .everyday: "Normal coding work"
        case .complex: "Design, hard bugs, big changes"
        }
    }

    private var rank: Int { Tier.allCases.firstIndex(of: self)! }
    static func < (a: Tier, b: Tier) -> Bool { a.rank < b.rank }
}

/// What a tier runs on. An empty field leaves that part to the agent's own setting.
struct TierChoice: Codable, Equatable {
    var model: String
    var effort: String
}

/// A session's own choice for its model or its effort (right-click the tab → Model / Effort).
enum Pick: Equatable {
    /// The router decides where it's turned on in Settings; otherwise the agent's own setting.
    case auto
    /// Always the agent's own setting.
    case own
    /// Always this model (or effort), whatever the router would choose.
    case fixed(String)

    /// As saved with the tab: nothing for automatic, "-" for the agent's own, else the name.
    init(saved: String?) {
        switch saved {
        case nil: self = .auto
        case "-"?: self = .own
        case let value?: self = .fixed(value)
        }
    }

    var saved: String? {
        switch self {
        case .auto: nil
        case .own: "-"
        case .fixed(let value): value
        }
    }
}

/// Picks the model (and effort) for a job from the message you send.
///
/// A model is chosen when the agent starts, with its own launch flags; that is the one way all three agents
/// share, and it changes nothing in their settings. So switching means restarting the agent on the other model,
/// resuming the same conversation and handing it your message. A switch makes the agent read the whole
/// conversation again at full price (each model keeps its own cache), so the router switches only when that
/// pays: at the first message, up for clearly harder work, and down only while the conversation is still short
/// or after a pause long enough that it would be re-read anyway.
enum Router {
    // MARK: Settings

    static var routeModel: Bool {
        get { UserDefaults.standard.bool(forKey: "routerModel") }
        set { UserDefaults.standard.set(newValue, forKey: "routerModel") }
    }

    static var routeEffort: Bool {
        get { UserDefaults.standard.bool(forKey: "routerEffort") }
        set { UserDefaults.standard.set(newValue, forKey: "routerEffort") }
    }

    static var enabled: Bool { routeModel || routeEffort }

    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func defaultChoice(_ agent: Agent, _ tier: Tier) -> TierChoice {
        switch (agent, tier) {
        case (.claude, .simple): TierChoice(model: "sonnet", effort: "medium")
        case (.claude, .everyday): TierChoice(model: "opus", effort: "medium")
        case (.claude, .complex): TierChoice(model: "fable", effort: "high")
        // Which Codex and Antigravity models an account has differs, so those start on the agent's own model
        // and vary the effort; put model names in Settings to route between models too.
        case (_, .simple): TierChoice(model: "", effort: "low")
        case (_, .everyday): TierChoice(model: "", effort: "medium")
        case (_, .complex): TierChoice(model: "", effort: "high")
        }
    }

    private static var stored: [String: [String: TierChoice]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "routerTiers") else { return [:] }
            return (try? JSONDecoder().decode([String: [String: TierChoice]].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "routerTiers") }
    }

    static func choice(_ agent: Agent, _ tier: Tier) -> TierChoice {
        stored[agent.rawValue]?[tier.rawValue] ?? defaultChoice(agent, tier)
    }

    static func setChoice(_ choice: TierChoice, _ agent: Agent, _ tier: Tier) {
        let clean = TierChoice(model: choice.model.trimmingCharacters(in: .whitespaces),
                               effort: choice.effort.trimmingCharacters(in: .whitespaces))
        guard clean != self.choice(agent, tier) else { return } // a field re-sending its text isn't an edit
        var all = stored
        all[agent.rawValue, default: [:]][tier.rawValue] = clean == defaultChoice(agent, tier) ? nil : clean
        stored = all
    }

    /// Whether the router has anything to decide for a session with these picks.
    static func routes(model: Pick, effort: Pick) -> Bool {
        (model == .auto && routeModel) || (effort == .auto && routeEffort)
    }

    /// What a session starts on: its own picks first, then its tier's choice where the router is on. nil
    /// leaves that part to the agent's own setting.
    static func setup(_ agent: Agent, tier: Tier?, model: Pick, effort: Pick) -> (model: String?, effort: String?) {
        let routed = tier.map { choice(agent, $0) }
        func resolve(_ pick: Pick, _ automatic: Bool, _ value: String?) -> String? {
            let name: String?
            switch pick {
            case .fixed(let own): name = own
            case .own: name = nil
            case .auto: name = automatic ? value : nil
            }
            return name?.isEmpty == false ? name : nil
        }
        return (resolve(model, routeModel, routed?.model), resolve(effort, routeEffort, routed?.effort))
    }

    /// The launch flags that put `agent` on that model and effort.
    static func flags(_ agent: Agent, tier: Tier?, model: Pick = .auto, effort: Pick = .auto) -> [String] {
        let s = setup(agent, tier: tier, model: model, effort: effort)
        var out: [String] = []
        if let model = s.model { out += [agent == .codex ? "-m" : "--model", model] }
        if let effort = s.effort { out += agent == .codex ? ["-c", "model_reasoning_effort=\(effort)"] : ["--effort", effort] }
        return out
    }

    /// "Opus · medium": what a session runs on, for the sidebar; nil when both are the agent's own.
    static func label(_ agent: Agent, tier: Tier?, model: Pick = .auto, effort: Pick = .auto) -> String? {
        let s = setup(agent, tier: tier, model: model, effort: effort)
        let parts = [s.model.map { modelName(agent, $0) }, s.effort].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The models a session's Model menu offers: the agent's known ones, the ones your tiers use, and `also`
    /// (the one the session is on, if you typed it yourself).
    static func models(_ agent: Agent, also: String? = nil) -> [String] {
        var list: [String]
        switch agent {
        case .claude: list = ["haiku", "sonnet", "opus", "fable"]
        case .codex: list = codexModels()
        case .antigravity:
            refreshAntigravityModels()
            list = antigravityModels.map(\.slug)
        }
        for model in Tier.allCases.map({ choice(agent, $0).model }) + [also ?? ""] where !model.isEmpty && !list.contains(model) {
            list.append(model)
        }
        return list
    }

    /// A model's name for menus and the sidebar.
    static func modelName(_ agent: Agent, _ model: String) -> String {
        if agent == .antigravity, let known = antigravityModels.first(where: { $0.slug == model }) { return known.label }
        return prettyModel(model)
    }

    /// Antigravity's models as `agy models` last listed them ("slug<tab>label" per line).
    private static var antigravityModels: [(slug: String, label: String)] {
        (UserDefaults.standard.stringArray(forKey: "antigravityModels") ?? []).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private static var antigravityAsked = Date.distantPast

    /// Asks `agy models` in the background, at most every few hours; the menu shows the new list next time.
    private static func refreshAntigravityModels() {
        guard Date().timeIntervalSince(antigravityAsked) > 6 * 3600 else { return }
        antigravityAsked = Date()
        DispatchQueue.global(qos: .utility).async {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", "agy models"] // the login shell knows where agy is
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let lines = text.split(separator: "\n").map(String.init).filter { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                return parts.count == 2 && !parts[0].contains(" ")
            }
            if !lines.isEmpty { UserDefaults.standard.set(lines, forKey: "antigravityModels") }
        }
    }

    static func prettyModel(_ model: String) -> String {
        let known = ["fable": "Fable", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        let lower = model.lowercased()
        if let name = known[lower] { return name }
        if lower.hasPrefix("claude-"), let hit = known.first(where: { lower.contains($0.key) }) { return hit.value }
        return model
    }

    /// The tier a conversation is on, from the model (and effort) its last reply was written with. `byModel` /
    /// `byEffort`: which of the two the router chooses for that session, and so tells tiers apart.
    static func tier(_ agent: Agent, model: String, effort: String?, byModel: Bool, byEffort: Bool) -> Tier? {
        let model = model.lowercased(), effort = effort?.lowercased()
        func modelFits(_ tier: Tier) -> Bool {
            let wanted = choice(agent, tier).model.lowercased().replacingOccurrences(of: "[1m]", with: "")
            return !byModel || wanted.isEmpty || model == wanted || model.contains(wanted)
        }
        func effortFits(_ tier: Tier) -> Bool {
            let wanted = choice(agent, tier).effort.lowercased()
            return !byEffort || wanted.isEmpty || effort == nil || effort == wanted
        }
        let both = Tier.allCases.filter { modelFits($0) && effortFits($0) }
        if both.count == 1 { return both[0] }
        // On a tier's model at an effort of your own: the model says which tier.
        let sameModel = Tier.allCases.filter(modelFits)
        return both.isEmpty && byModel && sameModel.count == 1 ? sameModel[0] : nil
    }

    /// Whether a conversation of any size fits `tier`'s model (you named a 1M-token variant, e.g. "sonnet[1m]").
    static func holdsAnything(_ agent: Agent, _ tier: Tier) -> Bool {
        !routeModel || choice(agent, tier).model.lowercased().contains("[1m]")
    }

    /// What to type in a tier's Model field, per agent (Settings).
    static func modelHelp(_ agent: Agent) -> String {
        switch agent {
        case .claude:
            return "Model: haiku, sonnet, opus, fable, or a full model name. Add [1m] (e.g. sonnet[1m]) for the 1M-token variant, which also lets a long conversation move down to it."
        case .codex:
            let models = codexModels()
            return "Leave Model empty to stay on Codex's own model and change only the effort."
                + (models.isEmpty ? "" : " Your account's models: \(models.joined(separator: ", ")).")
        case .antigravity:
            return "Leave Model empty to stay on Antigravity's own model and change only the effort. `agy models` in a shell tab lists the model names."
        }
    }

    /// Models Codex last listed for your account (~/.codex/models_cache.json).
    static func codexModels() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else { return [] }
        return models.filter { $0["visibility"] as? String == "list" }.compactMap { $0["slug"] as? String }
    }

    // MARK: Judging a message

    struct Verdict: Equatable {
        var tier: Tier
        /// A short reply to what's already going on ("yes", "continue"): no reason to change anything.
        var followUp = false
        /// You named the model yourself ("use Fable for this").
        var explicit = false
        var reason: String
    }

    private static let complexSignals: [(pattern: String, weight: Int)] = [
        (#"\b(architect\w*|re-?architect\w*|re-?design\w*|system design|design (a|an|the|new|our)\b)"#, 3),
        (#"\b(rewrite|re-write|from scratch|migrat\w+|port (it|this|the \w+) to)\b"#, 2),
        (#"\b(race condition|deadlock|concurren\w+|thread[- ]safe\w*|memory leak|data (loss|corruption)|corrupt\w*)\b"#, 3),
        (#"\b(root cause|investigat\w+|figure out why|can'?t figure|cannot figure|no idea why|intermittent\w*|flaky|sometimes (fails|crashes|works|breaks))\b"#, 3),
        (#"\b(still (not|doesn'?t|isn'?t|broken|fails|failing|happening|wrong)|again and again|over and over|keeps (failing|crashing|happening|asking))\b"#, 2),
        (#"\b(security (audit|review|hole|issue)|vulnerab\w+|threat model|exploit\w*)\b"#, 3),
        (#"\b(performance|optimi[sz]\w+|bottleneck\w*|profil(e|ing)|scalab\w+)\b"#, 2),
        (#"\b(algorithm\w*|invariant\w*|proof|prove|formal\w*|state machine)\b"#, 2),
        (#"\b(research|trade-?offs?|pros and cons|compare (the )?(options|approaches|alternatives)|strategy|roadmap|plan (out|how|the)|best (way|approach))\b"#, 2),
        (#"\b(ultrathink|think (hard|harder|deeply|carefully|through|step by step)|very carefully|thorough\w*|deep dive)\b"#, 3),
        (#"\b(complex\w*|complicated|tricky|difficult|hard (problem|bug|one)|non-?trivial)\b"#, 2),
        (#"\b(refactor\w*|restructur\w+|reorgani[sz]\w+)\b"#, 2),
        (#"\b(implement\w*|build|develop)\b"#, 1),
        (#"\b(feature|system|engine|router|service|pipeline|integration|sync\w*|parser|compiler|protocol|framework|scheduler|database schema)\b"#, 1),
        (#"\b(end[- ]to[- ]end|whole (app|codebase|project|repo)|entire (app|codebase|project|repo)|across (the )?(whole |entire )?(codebase|project|app|repo)|every (file|module|screen))\b"#, 2),
    ]

    private static let simpleSignals: [(pattern: String, weight: Int)] = [
        (#"\b(commit (it|this|that|and)|push (it|this|that)|bump (the )?version|update (the )?changelog)\b"#, 2),
        (#"\b(typos?|rename|reformat|lint|indent\w*|spelling|wording|capitali[sz]\w+|docstrings?)\b"#, 2),
        (#"\b(explain|summari[sz]e|translate|describe|what does .{0,40} (do|mean))\b"#, 1),
        (#"\b(quick\w*|simple|small|tiny|minor|trivial|one[- ]liner?|just)\b"#, 1),
    ]

    /// How a short message opens: a lookup ("what is…", "show me…") or a chore ("run the tests").
    private static let simpleOpeners: [(pattern: String, weight: Int)] = [
        (#"^(git )?(commit|push|pull|merge|rebase|stash|tag|bump)\b"#, 3),
        (#"^(run|rerun|re-run|restart|open|launch|install|show|list|print|check|read|find|search|look at|tell me|remind me)\b"#, 2),
        (#"^(what|where|which|who|when|why|how (do|does|did|to|many|much|long)|(is|are|was|does|did) (it|there|this|that|the)|do (i|we|you|they))\b"#, 2),
    ]

    /// Polite lead-ins that say nothing about the job ("can you…", "please…", "and now…").
    private static let leadIn = #"^((hey|hi|ok|okay|so|and|also|now|then|please|pls|can (you|u)|could (you|u)|would (you|u)|will (you|u)|i (want|need|would like) (you )?to|i'd like (you )?to|let'?s|is it possible to|is there a way to)[,.! ]+)+"#

    private static let followUps: Set<String> = [
        "yes", "yep", "yeah", "ok", "okay", "sure", "no", "nope", "go", "go ahead", "go on", "do it", "do that",
        "continue", "proceed", "next", "thanks", "thank you", "good", "great", "perfect", "nice", "looks good",
        "lgtm", "try again", "again", "retry", "fix it", "fix that", "sounds good", "yes please", "please do",
        "да", "не", "добре", "продължи", "давай",
    ]

    /// Which tier a message asks for.
    static func classify(_ text: String, agent: Agent) -> Verdict {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let named = namedTier(lower, agent: agent) {
            return Verdict(tier: named.tier, explicit: true, reason: "you asked for \(named.word)")
        }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).count
        let bare = lower.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        var score = 0
        var why: [String] = []
        func scan(_ signals: [(pattern: String, weight: Int)], sign: Int) -> Int {
            var total = 0
            for (pattern, weight) in signals {
                guard let range = lower.range(of: pattern, options: .regularExpression) else { continue }
                total += weight
                score += sign * weight
                why.append(String(lower[range]))
            }
            return total
        }
        let opening = lower.replacingOccurrences(of: leadIn, with: "", options: .regularExpression)
        let bareOpening = opening.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if followUps.contains(bare) || followUps.contains(bareOpening) || bareOpening.isEmpty {
            return Verdict(tier: .everyday, followUp: true, reason: "short reply")
        }
        let hard = scan(complexSignals, sign: 1)
        var easy = scan(simpleSignals, sign: -1)
        // A short message that opens like a lookup or a chore; longer ones that start this way are requests.
        if words <= 25 {
            for (pattern, weight) in simpleOpeners {
                guard let range = opening.range(of: pattern, options: .regularExpression) else { continue }
                easy += weight
                score -= weight
                why.append(String(opening[range]))
            }
        }
        if words <= 4 && hard == 0 && easy == 0 {
            return Verdict(tier: .everyday, followUp: true, reason: "short reply")
        }
        // Long, many-part requests are rarely simple.
        if lower.count > 1500 { score += 2; why.append("long request") }
        else if lower.count > 600 { score += 1; why.append("long request") }
        let parts = lower.split(separator: "\n").filter { line in
            line.range(of: #"^\s*([-*•]|\d+[.)])\s"#, options: .regularExpression) != nil
        }.count
        if parts >= 4 { score += 1; why.append("\(parts) steps") }
        if words <= 10, hard == 0 { score -= 1 }
        let tier: Tier = score >= 3 ? .complex : score <= -2 ? .simple : .everyday
        let shown = why.prefix(3).joined(separator: ", ")
        return Verdict(tier: tier, reason: shown.isEmpty ? "no special signals" : shown)
    }

    /// "use fable", "with the best model", "on a cheaper model": the tier you asked for in the message itself.
    private static func namedTier(_ lower: String, agent: Agent) -> (tier: Tier, word: String)? {
        // "use …" asks outright; "with …" / "on …" only where they close a sentence ("fix it with fable."), so
        // that talking about models ("why did it run on sonnet yesterday?") changes nothing.
        func asked(_ what: String) -> Range<String.Index>? {
            lower.range(of: #"\b(use|using|switch to|route (this |it )?to)\s+(the |a |an )?"# + what + #"\b"#, options: .regularExpression)
                ?? lower.range(of: #"\b(with|on)\s+(the |a |an )?"# + what + #"\s*([:.,;!]|$)"#, options: .regularExpression)
        }
        for tier in Tier.allCases.reversed() {
            let model = choice(agent, tier).model.lowercased().replacingOccurrences(of: "[1m]", with: "")
            guard !model.isEmpty else { continue }
            if asked(NSRegularExpression.escapedPattern(for: model)) != nil { return (tier, prettyModel(model)) }
        }
        let wanted: [(Tier, String)] = [
            (.complex, "(best|strongest|smartest|most powerful|most capable|top|biggest|heavy|deep) model"),
            (.simple, "(cheap|cheaper|cheapest|fast|faster|fastest|small|smaller|smallest|light|lighter|lightest) model"),
            (.everyday, "(normal|default|standard|everyday|regular|usual|middle) model"),
        ]
        for (tier, words) in wanted {
            if let range = asked(words) {
                return (tier, "\"" + lower[range].trimmingCharacters(in: CharacterSet(charactersIn: " :.,;!")) + "\"")
            }
        }
        return nil
    }

    // MARK: Deciding

    /// A conversation left alone this long is re-read at full price on any model, so re-routing it is free.
    static let coldAfter: TimeInterval = 60 * 60
    /// A conversation still this short (tokens; an agent's own instructions take most of it) costs little to
    /// re-read and has little history a lighter model could lose track of, so it may move down right away.
    static let shortConversation = 60_000
    /// Lighter models may hold less; don't hand them a conversation larger than this (tokens).
    static let stepDownLimit = 150_000

    struct Situation {
        /// The tier the tab runs on, when known.
        var current: Tier?
        /// No conversation yet: any model can take it at no extra cost.
        var fresh: Bool
        /// When the conversation last moved.
        var lastActivity: Date?
        /// Tokens the conversation holds, when known.
        var contextTokens: Int?
        /// Tiers whose model takes a conversation of any size.
        var roomy: Set<Tier> = []
    }

    /// The tier to switch to before this message is sent, or nil to send it where the tab already is.
    static func decide(_ verdict: Verdict, _ s: Situation, now: Date = Date()) -> Tier? {
        func changed(_ tier: Tier) -> Tier? { tier == s.current ? nil : tier }
        if verdict.explicit { return changed(verdict.tier) }
        if s.fresh { return verdict.followUp ? nil : changed(verdict.tier) }
        if verdict.followUp { return nil }
        let cold = s.lastActivity.map { now.timeIntervalSince($0) >= coldAfter } ?? false
        let short = s.contextTokens.map { $0 <= shortConversation } ?? false
        let fits = (s.contextTokens ?? 0) <= stepDownLimit || s.roomy.contains(verdict.tier)
        // Moving down, or choosing for a tab whose model is unknown (the router didn't start it), only where
        // that costs little: the conversation is short, or it rested long enough to be re-read anyway.
        let free = (cold || short) && fits
        guard let current = s.current else { return free ? verdict.tier : nil }
        if verdict.tier > current { return verdict.tier }
        if verdict.tier < current, free { return verdict.tier }
        return nil
    }
}
