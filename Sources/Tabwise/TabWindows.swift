import AppKit
import SwiftUI

/// Small windows opened from a tab's right-click menu: Schedule Message… and Auto-Allowed Commands….
@MainActor
enum TabWindows {
    private static var windows: [String: NSWindow] = [:]

    private static func show(_ key: String, title: String, size: NSSize, _ view: some View) {
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        windows[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows[key] = nil }
        }
        w.makeKeyAndOrderFront(nil)
    }

    static func schedule(_ tab: SessionTab, store: DeckStore) {
        show("schedule-\(tab.id)", title: "Scheduled Messages — \(tab.displayName)", size: NSSize(width: 520, height: 440),
             ScheduleView(tab: tab, store: store))
    }

    static func autoAllowed(_ tab: SessionTab) {
        show("allowed-\(tab.id)", title: "Auto-Allowed Commands — \(tab.displayName)", size: NSSize(width: 640, height: 420),
             AutoAllowedView(tab: tab))
    }
}

struct ScheduleView: View {
    @ObservedObject var tab: SessionTab
    let store: DeckStore
    @State private var text = ""
    @State private var at = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send this message to \(tab.agent?.name ?? "the agent") at a set time. If it's busy then, the message waits for the turn to finish, like a queued one; a sleeping session is woken for it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                DatePicker("Send at", selection: $at, in: Date()...)
                Spacer()
                Button("Schedule") {
                    store.schedule(tab, text, at: at)
                    text = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 6) {
                Text("Quick:").foregroundStyle(.secondary)
                ForEach([(15, "15 min"), (60, "1 hour"), (180, "3 hours")], id: \.0) { minutes, label in
                    Button(label) { at = Date().addingTimeInterval(Double(minutes) * 60) }.buttonStyle(.link)
                }
                Button("Tomorrow 9:00") {
                    let day = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                    at = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? at
                }.buttonStyle(.link)
            }
            .font(.callout)
            Divider()
            if tab.scheduled.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(tab.scheduled) { item in
                        HStack(alignment: .top) {
                            Text(item.at.formatted(date: .abbreviated, time: .shortened))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            Text(item.text).lineLimit(3)
                            Spacer()
                            Button { store.unschedule(tab, item.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).help("Don't send it")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

struct AutoAllowedView: View {
    let tab: SessionTab
    @State private var entries: [(at: Date?, what: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commands auto mode blocked and Tabwise let through in this session (Auto-allow What Auto Mode Blocks), newest first. Kept for the last 200.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty {
                Text("Nothing was auto-allowed in this session yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.at.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                        Text(entry.what).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Refresh") { entries = tab.autoAllowedLog }
            }
        }
        .padding(16)
        .onAppear { entries = tab.autoAllowedLog }
    }
}
