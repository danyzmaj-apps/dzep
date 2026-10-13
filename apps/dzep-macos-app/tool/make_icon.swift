// Draws the app icon: a pocket ("džep") with a note tucked in, on the app's dark gradient.
//   swift tool/make_icon.swift   (in apps/dzep-macos-app)
//     → ../dzep-mobile/assets/icon/ios.png (square, opaque)
//       ../dzep-mobile/assets/icon/android-background.png, android-foreground.png
//         (Android's adaptive icon: the gradient, and the pocket alone inside the safe zone)
//       assets/icon/macos.png (rounded, padded)
// Then in each app: fvm dart run flutter_launcher_icons
import AppKit

/// [gradient]/[art]: which layers to draw; [scale]: the art's size around
/// the centre (Android's mask shows only the middle of its foreground).
func render(
  size: CGFloat, inset: CGFloat, radius: CGFloat, gradient: Bool = true, art: Bool = true, scale: CGFloat = 1,
  to path: String
) {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  if gradient {
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(
      starting: NSColor(red: 0.20, green: 0.24, blue: 0.40, alpha: 1),
      ending: NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
    )!.draw(in: shape, angle: -60)
  }
  if art { drawArt(in: body.insetBy(dx: body.width * (1 - scale) / 2, dy: body.height * (1 - scale) / 2)) }
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

/// The note and the pocket, in [rect].
func drawArt(in rect: NSRect) {
  // Unit coordinates inside the body, y up.
  func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
  let w = rect.width

  // The note peeking out of the pocket, tilted; the pocket covers its lower half.
  NSGraphicsContext.saveGraphicsState()
  let tilt = NSAffineTransform()
  tilt.translateX(by: p(0.53, 0.66).x, yBy: p(0.53, 0.66).y)
  tilt.rotate(byDegrees: -9)
  tilt.concat()
  let note = NSBezierPath(
    roundedRect: NSRect(x: -0.19 * w, y: -0.16 * w, width: 0.38 * w, height: 0.36 * w), xRadius: 0.03 * w,
    yRadius: 0.03 * w)
  NSColor(red: 1, green: 0.82, blue: 0.36, alpha: 1).setFill()
  note.fill()
  NSColor(red: 0.80, green: 0.60, blue: 0.20, alpha: 1).setFill()
  for i in 0..<2 {
    NSBezierPath(
      roundedRect: NSRect(x: -0.12 * w, y: (0.09 - CGFloat(i) * 0.07) * w, width: (i == 0 ? 0.24 : 0.17) * w, height: 0.026 * w),
      xRadius: 0.013 * w, yRadius: 0.013 * w
    ).fill()
  }
  NSGraphicsContext.restoreGraphicsState()

  // The pocket: a jeans back pocket, square top, pointed bottom.
  let pocket = NSBezierPath()
  pocket.move(to: p(0.22, 0.60))
  pocket.line(to: p(0.78, 0.60))
  pocket.line(to: p(0.78, 0.33))
  pocket.line(to: p(0.50, 0.17))
  pocket.line(to: p(0.22, 0.33))
  pocket.close()
  pocket.lineJoinStyle = .round
  NSGradient(
    starting: NSColor(red: 0.55, green: 0.62, blue: 1.0, alpha: 1),
    ending: NSColor(red: 0.36, green: 0.42, blue: 0.86, alpha: 1)
  )!.draw(in: pocket, angle: -90)

  // Stitching just inside the edge, and the hem along the top.
  let stitch = NSBezierPath()
  stitch.move(to: p(0.255, 0.565))
  stitch.line(to: p(0.745, 0.565))
  stitch.line(to: p(0.745, 0.35))
  stitch.line(to: p(0.50, 0.21))
  stitch.line(to: p(0.255, 0.35))
  stitch.close()
  stitch.move(to: p(0.255, 0.535))
  stitch.line(to: p(0.745, 0.535))
  stitch.lineWidth = 0.011 * w
  stitch.lineCapStyle = .round
  stitch.setLineDash([0.022 * w, 0.02 * w], count: 2, phase: 0)
  NSColor(red: 1, green: 0.82, blue: 0.36, alpha: 0.9).setStroke()
  stitch.stroke()
}

for dir in ["assets/icon", "../dzep-mobile/assets/icon"] {
  try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}
render(size: 1024, inset: 0, radius: 0, to: "../dzep-mobile/assets/icon/ios.png")
// Android: a 108 dp layer of which a 72 dp middle shows (less on round masks); the pocket
// at 0.72 stays clear of every mask.
render(size: 1024, inset: 0, radius: 0, art: false, to: "../dzep-mobile/assets/icon/android-background.png")
render(
  size: 1024, inset: 0, radius: 0, gradient: false, scale: 0.72, to: "../dzep-mobile/assets/icon/android-foreground.png")
// macOS: Big Sur grid, 824 pt body inside the 1024 canvas.
render(size: 1024, inset: 100, radius: 185, to: "assets/icon/macos.png")
print("ok")
