import AppKit
import SwiftUI

/// A window listing a tab's queued messages (⌘↩ while the agent works): edit, reorder or remove them before
/// they go out. Nothing is sent while it's open, so the message you're editing can't leave half-written.
@MainActor
final class QueueEditor: NSObject, NSWindowDelegate {
    static let shared = QueueEditor()
    private var windows: [UUID: NSWindow] = [:]
    private var stores: [UUID: DeckStore] = [:]

    func show(_ tab: SessionTab, store: DeckStore) {
        if let w = windows[tab.id] { w.makeKeyAndOrderFront(nil); return }
        tab.queueEditing = true
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Queued Messages — \(tab.displayName)"
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        w.contentView = NSHostingView(rootView: QueueEditorView(tab: tab) { [weak w] in w?.close() })
        w.delegate = self
        w.center()
        windows[tab.id] = w
        stores[tab.id] = store
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let raw = w.identifier?.rawValue, let id = UUID(uuidString: raw)
        else { return }
        windows[id] = nil
        guard let store = stores.removeValue(forKey: id), let tab = store.tabs.first(where: { $0.id == id }) else { return }
        store.finishQueueEdit(tab)
    }
}

struct QueueEditorView: View {
    @ObservedObject var tab: SessionTab
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tab.queued.isEmpty
                 ? "No queued messages."
                 : "Sent one by one, top first, each after \(tab.agent?.name ?? "the agent") finishes the previous one. Nothing is sent while this window is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(tab.queued.indices), id: \.self) { i in row(i) }
                }
            }
            HStack {
                Button("Add Message") { tab.queued.append("") }
                Button("Remove All", role: .destructive) { tab.queued.removeAll() }
                    .disabled(tab.queued.isEmpty)
                Spacer()
                if tab.queuePaused, !tab.queued.isEmpty {
                    Toggle("Paused", isOn: $tab.queuePaused)
                        .help("Turn off to send them again once \(tab.agent?.name ?? "the agent") is done.")
                }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 260)
    }

    private func row(_ i: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(i + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                .padding(.top, 4)
            TextEditor(text: Binding(
                get: { tab.queued.indices.contains(i) ? tab.queued[i] : "" },
                set: { if tab.queued.indices.contains(i) { tab.queued[i] = $0 } }))
                .font(.body)
                .frame(minHeight: 44, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            VStack(spacing: 2) {
                Button { tab.queued.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0).help("Send earlier")
                Button { tab.queued.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == tab.queued.count - 1).help("Send later")
                Button { tab.queued.remove(at: i) } label: { Image(systemName: "trash") }
                    .help("Don't send this one")
            }
            .buttonStyle(.borderless)
        }
    }
}
