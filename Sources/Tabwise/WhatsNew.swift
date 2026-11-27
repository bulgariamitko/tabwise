import AppKit
import SwiftUI

/// Tabwise → What's New: the release notes (CHANGELOG.md, bundled with the app), newest first. Opens by itself
/// once after an update, so you see what changed.
@MainActor
enum WhatsNew {
    struct Release: Identifiable {
        let version: String
        let notes: [String]
        var id: String { version }
    }

    private static var window: NSWindow?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "## 0.1.25" starts a release; each "- " starts a note, and indented lines continue it.
    static func releases() -> [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Release] = []
        var version: String?
        var notes: [String] = []
        func flush() { if let version, !notes.isEmpty { out.append(Release(version: version, notes: notes)) } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                notes = []
            } else if line.hasPrefix("- ") {
                notes.append(String(line.dropFirst(2)))
            } else if !line.isEmpty, raw.hasPrefix(" "), !notes.isEmpty {
                notes[notes.count - 1] += " " + line
            }
        }
        flush()
        return out
    }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "What's New in Tabwise"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WhatsNewView(releases: releases(), current: currentVersion))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// At launch: open once when this version is newer than the one you last ran. Not on a first install.
    static func showIfUpdated() {
        let key = "whatsNewSeenVersion"
        let seen = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(currentVersion, forKey: key)
        guard let seen, seen != currentVersion,
              seen.compare(currentVersion, options: .numeric) == .orderedAscending,
              releases().first?.version == currentVersion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { show() }
    }
}

struct WhatsNewView: View {
    let releases: [WhatsNew.Release]
    let current: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if releases.isEmpty {
                    Text("Release notes aren't available in this build.").foregroundStyle(.secondary)
                }
                ForEach(releases) { release in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Version \(release.version)").font(.title3.weight(.semibold))
                            if release.version == current {
                                Text("Installed")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(Self.styled(note)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    if release.id != releases.last?.id { Divider() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// **bold**, `code` and links as Markdown; plain text if it doesn't parse.
    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
