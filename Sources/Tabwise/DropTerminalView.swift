import AppKit
import SwiftTerm

/// A terminal that accepts drops like Terminal.app: files paste as escaped paths (Claude Code turns image
/// paths into attached images), and raw image data is saved as a PNG first so it can be pasted the same way.
final class DropTerminalView: LocalProcessTerminalView {
    static let dropDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabwise/drops")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var highlight: NSView?
    /// Set by the owning tab: true while Claude Code (not just a shell) is running in this terminal.
    var claudeActive: () -> Bool = { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender.draggingPasteboard) else { return [] }
        showHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { showHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showHighlight(false)
        let paths = Self.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        pasteText(paths.map(Self.escape).joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// ⌘V: text pastes as usual; copied Finder files paste as paths; a clipboard image goes to Claude via
    /// Ctrl+V (Claude Code's own image paste), or is saved as a PNG and pasted as a path in a plain shell.
    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            pasteText(urls.map { Self.escape($0.path) }.joined(separator: " ") + " ")
            return
        }
        let hasImage = pb.availableType(from: [.png, .tiff]) != nil
        if hasImage && pb.string(forType: .string) == nil {
            if claudeActive() {
                send(txt: "\u{16}") // Ctrl+V
            } else {
                let paths = Self.paths(from: pb)
                if !paths.isEmpty { pasteText(paths.map(Self.escape).joined(separator: " ") + " ") }
            }
            return
        }
        super.paste(sender)
    }

    private func canAccept(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    static func paths(from pb: NSPasteboard) -> [String] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(\.path)
        }
        // Image with no file behind it (e.g. dragged from a browser): save it so Claude can read it.
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dropDir.appendingPathComponent("image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        guard (try? png.write(to: url)) != nil else { return [] }
        return [url.path]
    }

    /// Backslash-escape like Terminal.app does, so spaces and quotes in paths survive.
    static func escape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if ch.isLetter || ch.isNumber || "/._-+,@%:~".contains(ch) { out.append(ch) } else { out += "\\\(ch)" }
        }
        return out
    }

    /// Types `text` into the session as a paste; with `submit`, presses Return afterwards
    /// (slightly later, so the TUI sees it as a keypress rather than part of the paste).
    func insert(_ text: String, submit: Bool) {
        pasteText(text)
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.send(txt: "\r") }
        }
        if !isHidden { window?.makeFirstResponder(self) }
    }

    private func pasteText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        let payload = bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        send(txt: payload)
    }

    private func showHighlight(_ on: Bool) {
        if on, highlight == nil {
            let v = NSView(frame: bounds)
            v.autoresizingMask = [.width, .height]
            v.wantsLayer = true
            v.layer?.borderWidth = 2
            v.layer?.borderColor = NSColor.controlAccentColor.cgColor
            v.layer?.cornerRadius = 6
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
            addSubview(v)
            highlight = v
        } else if !on {
            highlight?.removeFromSuperview()
            highlight = nil
        }
    }
}
