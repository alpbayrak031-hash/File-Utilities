// Draws the app icon (1024×1024 PNG). Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background with a blue→indigo gradient
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.95, alpha: 1).setFill()
path.fill()
ctx.restoreGState()
path.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.25, green: 0.62, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.93, alpha: 1),
])!.draw(in: rect, angle: -60)

// Stacked "files" with symbols
func card(_ r: CGRect, _ symbol: String, _ tint: NSColor, rotation: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: r.midX, y: r.midY)
    ctx.rotate(by: rotation * .pi / 180)
    let local = CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.25)
    s.shadowBlurRadius = 18
    s.shadowOffset = NSSize(width: 0, height: -8)
    s.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: local, xRadius: 40, yRadius: 40).fill()
    NSShadow().set()
    let config = NSImage.SymbolConfiguration(pointSize: r.width * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [tint]))
    if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = sym.size
        sym.draw(in: CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height))
    }
    ctx.restoreGState()
}
card(CGRect(x: 250, y: 330, width: 300, height: 380), "doc.richtext.fill", NSColor.systemRed, rotation: 12)
card(CGRect(x: 474, y: 330, width: 300, height: 380), "film.fill", NSColor.systemPurple, rotation: -12)
card(CGRect(x: 362, y: 270, width: 300, height: 380), "photo.fill", NSColor.systemBlue, rotation: 0)

// Down-arrow badge (compression)
let badge = CGRect(x: 610, y: 190, width: 210, height: 210)
NSColor(calibratedRed: 0.18, green: 0.8, blue: 0.45, alpha: 1).setFill()
NSBezierPath(ovalIn: badge).fill()
let arrowConfig = NSImage.SymbolConfiguration(pointSize: 110, weight: .bold).applying(.init(paletteColors: [.white]))
if let arrow = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?.withSymbolConfiguration(arrowConfig) {
    arrow.draw(in: CGRect(x: badge.midX - arrow.size.width / 2, y: badge.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
