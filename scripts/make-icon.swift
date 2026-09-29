// Renders the app icon: dark rounded square, a stack of sidebar tabs, and a coral prompt.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
           ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: bg, angle: -90)

// Sidebar with three tabs; the top one is "active".
let coral = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
NSColor(white: 1, alpha: 0.06).setFill()
NSBezierPath(roundedRect: NSRect(x: rect.minX + 60, y: rect.minY + 60, width: 230, height: rect.height - 120), xRadius: 40, yRadius: 40).fill()
for (i, color) in [coral, NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0.35)].enumerated() {
    let y = rect.maxY - 170 - CGFloat(i) * 120
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.minX + 95, y: y, width: 44, height: 44)).fill()
    NSColor(white: 1, alpha: i == 0 ? 0.8 : 0.3).setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX + 155, y: y + 10, width: 100, height: 24), xRadius: 12, yRadius: 12).fill()
}

// Prompt "›_" in the terminal area.
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 300, weight: .bold),
    .foregroundColor: coral,
]
NSAttributedString(string: "›_", attributes: attrs).draw(at: NSPoint(x: rect.minX + 330, y: rect.midY - 190))
image.unlockFocus()

let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
