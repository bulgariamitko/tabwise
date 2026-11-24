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
    /// Text pasted into this session, newest last. Claude shows a long paste only as "[Pasted text #3 +4 lines]",
    /// so to take a message out of its box (⌘↩ stacking) Tabwise puts the pasted text back in its place.
    private(set) var recentPastes: [String] = []

    private func remember(_ text: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard t.contains("\n") || t.count > 200 else { return }
        recentPastes.append(t)
        if recentPastes.count > 40 { recentPastes.removeFirst(recentPastes.count - 40) }
    }

    /// `text` with each "[Pasted text #N +K lines]" replaced by what was pasted; nil if one can't be found.
    /// Placeholders are matched to pastes by line count, the newest paste going to the highest number.
    func expandPastes(_ text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"\[Pasted text #(\d+)(?: \+(\d+) lines?)?\]"#)
        let ns = text as NSString
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return text }
        var used = Set<Int>(), fill = [Int: String]() // match index -> pasted text
        let byNumber = found.indices.sorted {
            Int(ns.substring(with: found[$0].range(at: 1)))! > Int(ns.substring(with: found[$1].range(at: 1)))!
        }
        for i in byNumber {
            let r = found[i].range(at: 2)
            let lines = r.location == NSNotFound ? 0 : Int(ns.substring(with: r))!
            guard let j = recentPastes.indices.reversed().first(where: {
                !used.contains($0) && recentPastes[$0].filter { $0 == "\n" }.count == lines
            }) else { return nil }
            used.insert(j)
            fill[i] = recentPastes[j]
        }
        var out = text
        for i in found.indices.reversed() {
            out = (out as NSString).replacingCharacters(in: found[i].range, with: fill[i]!)
        }
        return out
    }
    /// Set by the owning tab: true while Claude Code (not just a shell) is running in this terminal.
    var claudeActive: () -> Bool = { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        // Links (and file paths) underline on hover and open with a plain click, not only ⌘-click.
        linkHighlightMode = .hover
        _ = Self.deleteWordMonitor
        _ = Self.returnMonitor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// ⌘⌫ and ⌥⌫ delete the previous word (repeating while held), like a Mac text field. Sent as ⌃W,
    /// which Claude Code's input box and the shell both treat as "delete word". SwiftTerm's keyDown
    /// can't be overridden, so a local key monitor catches them before the terminal does.
    private static let deleteWordMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 51, mods == .command || mods == .option, // Delete (backspace)
              let terminal = event.window?.firstResponder as? DropTerminalView else { return event }
        terminal.send(txt: "\u{17}")
        return nil
    }

    /// Set by the owning tab: Return was pressed here. True when the model router took the message over (it
    /// restarts the agent on another model and sends the message itself), so the key must not reach the agent.
    var routeReturn: () -> Bool = { false }

    /// Plain Return goes past the model router first. Not while an input method is composing: there Return
    /// only confirms the word.
    private static let returnMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 36 || event.keyCode == 76, mods.isEmpty, !event.isARepeat,
              let terminal = event.window?.firstResponder as? DropTerminalView, !terminal.hasMarkedText() else { return event }
        return terminal.routeReturn() ? nil : event
    }

    // MARK: Session IDs as links

    /// Set by the store: whether a session ID belongs to a session Tabwise can open, and opening it.
    static var knowsSession: (String) -> Bool = { _ in false }
    static var openSession: (String) -> Void = { _ in }

    private static let sessionIdPattern = try! NSRegularExpression(
        pattern: "(?<![0-9A-Fa-f-])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9A-Fa-f-])")

    /// The width and height of one character cell. SwiftTerm keeps its own private; the optimal frame is
    /// exactly that cell size times the grid (plus the scroller on the width, so the width comes from the font).
    private var cellSize: CGSize? {
        let t = getTerminal()
        guard t.rows > 0, t.cols > 0 else { return nil }
        let height = getOptimalFrameSize().height / CGFloat(t.rows)
        // As SwiftTerm measures it: the advance of "W", snapped to the pixel grid.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = (font.advancement(forGlyph: font.glyph(withName: "W")).width * scale).rounded() / scale
        return height > 0 && width > 0 ? CGSize(width: width, height: height) : nil
    }

    /// The known session ID under a point in the view, if there is one.
    func sessionId(at point: NSPoint) -> String? {
        guard let cell = cellSize else { return nil }
        let t = getTerminal()
        let row = Int((frame.height - point.y) / cell.height)
        let col = Int(point.x / cell.width)
        guard row >= 0, row < t.rows, let line = t.getLine(row: row) else { return nil }
        let text = line.translateToString(trimRight: true)
        let ns = text as NSString
        for match in Self.sessionIdPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // Columns before the ID: count characters, so wide ones before it would only shift it a little.
            let start = (ns.substring(to: match.range.location) as String).count
            guard col >= start - 1, col <= start + match.range.length else { continue }
            let id = ns.substring(with: match.range)
            return Self.knowsSession(id) ? id : nil
        }
        return nil
    }

    private var clickStart: NSPoint?
    private var linkTracking: NSTrackingArea?
    private var pointing = false

    override func mouseDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        clickStart = plain && event.clickCount == 1 ? convert(event.locationInWindow, from: nil) : nil
        super.mouseDown(with: event)
    }

    /// A plain click (not a drag or a double-click) on a session ID resumes that session in a tab, or switches
    /// to its tab when it's already open.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let point = convert(event.locationInWindow, from: nil)
        defer { clickStart = nil }
        guard let start = clickStart, hypot(point.x - start.x, point.y - start.y) < 4, !selectionActive,
              let id = sessionId(at: point) else { return }
        Self.openSession(id)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTracking { removeTrackingArea(linkTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: hoverOwner, userInfo: nil)
        addTrackingArea(area)
        linkTracking = area
    }

    /// The pointing hand over a session ID. SwiftTerm's own mouseMoved can't be overridden, so a separate
    /// tracking area reports the pointer here.
    private lazy var hoverOwner = HoverOwner { [weak self] event, inside in
        guard let self else { return }
        let over = inside && self.sessionId(at: self.convert(event.locationInWindow, from: nil)) != nil
        if over { NSCursor.pointingHand.set() } else if self.pointing { NSCursor.iBeam.set() }
        self.pointing = over
    }

    final class HoverOwner: NSResponder {
        let moved: (NSEvent, Bool) -> Void
        init(_ moved: @escaping (NSEvent, Bool) -> Void) { self.moved = moved; super.init() }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func mouseMoved(with event: NSEvent) { moved(event, true) }
        override func mouseExited(with event: NSEvent) { moved(event, false) }
    }

    /// The view shows the live bottom of the terminal, not an earlier part you scrolled back to.
    var atBottom: Bool { !canScroll || scrollPosition >= 1 }

    private var repaintScheduled = false

    /// SwiftTerm only repaints the rows it thinks changed, and Claude Code's in-place redraws (the
    /// slash-command list above the input box) can leave rows showing stale text. Once output settles,
    /// repaint the whole visible screen, which is cheap at most once per burst.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard !repaintScheduled, !isHidden else { return }
        repaintScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.repaintScheduled = false
            self.needsDisplay = true
        }
    }

    override var isHidden: Bool {
        didSet { if !isHidden, oldValue { needsDisplay = true } } // switching back to a tab
    }

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
        if let text = pb.string(forType: .string) { remember(text) }
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
        remember(text)
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
