// Draws the app icon: a warm SF Symbol lightbulb on the app's dark gradient.
//   swift tool/make_icon.swift   → assets/icon/ios.png (square, opaque)
//                                  assets/icon/macos.png (rounded, padded)
// Then: fvm dart run flutter_launcher_icons
import AppKit

func render(size: CGFloat, inset: CGFloat, radius: CGFloat, to path: String) {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  NSGradient(
    starting: NSColor(red: 0.20, green: 0.24, blue: 0.40, alpha: 1),
    ending: NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
  )!.draw(in: shape, angle: -60)
  let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .regular)
    .applying(.init(paletteColors: [NSColor(red: 1, green: 0.82, blue: 0.36, alpha: 1)]))
  let bulb = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
  let b = bulb.size
  bulb.draw(in: NSRect(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2, width: b.width, height: b.height))
  image.unlockFocus()

  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try! FileManager.default.createDirectory(atPath: "assets/icon", withIntermediateDirectories: true)
render(size: 1024, inset: 0, radius: 0, to: "assets/icon/ios.png")
// macOS: Big Sur grid, 824 pt body inside the 1024 canvas.
render(size: 1024, inset: 100, radius: 185, to: "assets/icon/macos.png")
print("ok")
