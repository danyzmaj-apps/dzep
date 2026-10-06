import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ServiceManagement

/// The app's only window, from MainMenu.xib. It takes two shapes, driven
/// from Dart over the `dzep/native` channel:
/// - **popup**: borderless, floating above everything (full-screen apps
///   included), on the screen under the mouse, no traffic lights.
/// - **main**: a normal titled window with a transparent, content-filled
///   title bar (Flutter draws the whole surface).
///
/// It's a non-activating panel (`nonactivatingPanel` in the xib's style mask):
/// since macOS 14 a background app can't take focus from the frontmost one
/// (`activate` is a request the system may refuse), and AppKit only honours
/// `.nonactivatingPanel` when a window is *created* with it. Such a panel
/// becomes key without activating Džep, which is how Spotlight-style
/// launchers take the keyboard.
class MainFlutterWindow: NSPanel, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var statusItem: NSStatusItem?

  /// Which shape the window is in. The main window's frame is remembered
  /// only while it really is the main window, never from launch or popup
  /// geometry.
  private enum Shape { case none, popup, main }
  private var shape = Shape.none
  private var mainFrame: NSRect?
  private static let mainMinSize = NSSize(width: 820, height: 480)

  /// Set while Džep hides the window itself, so that hiding isn't reported
  /// to Dart as the user clicking away ("blur"); a late blur would close a
  /// popup the next hotkey press had just opened.
  private var hidingOnPurpose = false

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    // Assigning a content view controller resizes the window to the view's
    // (tiny) size; keep the nib frame, as Flutter's template does.
    let nibFrame = frame
    self.contentViewController = flutterViewController
    setFrame(nibFrame, display: false)
    RegisterGeneratedPlugins(registry: flutterViewController)

    channel = FlutterMethodChannel(
      name: "dzep/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    delegate = self
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    setupStatusItem()
    super.awakeFromNib()
    // The xib keeps this window hidden at launch (no empty window flashing
    // up), but FlutterViewController only starts its engine when its view
    // appears: show it once, invisibly, and take it down on the next turn.
    // Dart then shows the shape it needs.
    alphaValue = 0
    orderFrontRegardless()
    DispatchQueue.main.async { [weak self] in
      self?.orderOut(nil)
      self?.alphaValue = 1
    }
  }

  // MARK: - Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "showPopup":
      request(.popup)
      result(nil)
    case "showMain":
      request(.main)
      result(nil)
    case "hide":
      // The panel never activated Džep, so the previous app still has focus.
      request(.hidden)
      result(nil)
    case "setHotKey":
      result(setHotKey(keyCode: args["keyCode"] as? Int ?? -1, modifiers: args["modifiers"] as? Int ?? 0))
    case "deviceName":
      result(Host.current().localizedName ?? "Mac")
    case "launchAtLogin":
      result(SMAppService.mainApp.status == .enabled)
    case "setLaunchAtLogin":
      do {
        if args["enabled"] as? Bool == true {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        result(SMAppService.mainApp.status == .enabled)
      } catch {
        result(FlutterError(code: "launch_at_login", message: error.localizedDescription, details: nil))
      }
    case "startDrag":
      if let event = currentEvent { performDrag(with: event) }
      result(nil)
    case "setTodoCount":
      // "💡 3" in the menu bar: open todos at a glance.
      let count = args["count"] as? Int ?? 0
      statusItem?.button?.title = count > 0 ? " \(count)" : ""
      result(nil)
    case "quit":
      NSApp.terminate(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The popup window never changes size: Flutter draws (and animates) the
  /// panel inside a fixed, transparent window. Flutter blocks the main thread
  /// after any window resize until it has drawn a frame at the new size (up
  /// to a second), which is what made opening and choosing 1/2/3 stall.
  static let popupSize = NSSize(width: 720, height: 660)

  /// Switching shape (main ↔ popup) is still a resize, and a hidden window
  /// never draws: put it on screen transparent first so Flutter can draw the
  /// new size right away, then reveal it.
  private func present(at target: NSRect) {
    if !isVisible {
      alphaValue = 0
      orderFrontRegardless()
    }
    resumeFlutter()
    setFrame(target, display: true)
    makeKey()
    alphaValue = 1
  }

  /// Flutter's engine only draws while it believes the app is visible, and
  /// it reads that from NSApplication's occlusion state, which stays "not
  /// visible" for a non-activating panel ordered in at alpha 0. In that
  /// state frames stop: the popup comes up blank and every resize waits out
  /// Flutter's one-second timeout. Džep knows the window is on screen, so it
  /// says so on the engine's own lifecycle channel.
  private func resumeFlutter() {
    guard let flutter = contentViewController as? FlutterViewController else { return }
    flutter.engine.binaryMessenger.send(
      onChannel: "flutter/lifecycle", message: "AppLifecycleState.resumed".data(using: .utf8))
  }

  /// What Dart asked the window to be.
  private enum Target { case hidden, popup, main }
  private var pending: Target?
  private var lastShapeChange = Date.distantPast

  /// Switching between the popup and main shapes resizes the window, and
  /// Flutter's renderer (Impeller) crashes when resizes come back to back.
  /// Dart no longer ping-pongs shapes (the hotkey opens a panel inside the
  /// main window), but as a guard: shape changes are spaced at least this
  /// far apart, and only the latest request is applied. Hiding is immediate.
  private static let shapeChangeSpacing: TimeInterval = 0.3

  private func request(_ target: Target) {
    let changesShape = (target == .popup && shape != .popup) || (target == .main && shape != .main)
    let wait = Self.shapeChangeSpacing - Date().timeIntervalSince(lastShapeChange)
    if changesShape && wait > 0 {
      let alreadyScheduled = pending != nil
      pending = target
      if !alreadyScheduled {
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
          guard let self, let next = self.pending else { return }
          self.pending = nil
          self.request(next)
        }
      }
      return
    }
    pending = nil
    if changesShape { lastShapeChange = Date() }
    switch target {
    case .hidden: hide()
    case .popup: showPopup()
    case .main: showMain()
    }
  }

  private func hide() {
    if shape == .main { mainFrame = frame }
    hidingOnPurpose = true
    orderOut(nil)
    hidingOnPurpose = false
  }

  private func showPopup() {
    if shape == .main { mainFrame = frame }
    shape = .popup
    let popupMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView, .nonactivatingPanel]
    if styleMask != popupMask { styleMask = popupMask }
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    // Flutter draws the panel's shadow; the window itself is mostly empty.
    hasShadow = false
    isMovable = false
    let size = Self.popupSize
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let top = visible.maxY - visible.height * 0.18
    present(at: NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height))
  }

  private func showMain() {
    shape = .main
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    level = .normal
    collectionBehavior = [.managed]
    isMovable = true
    isMovableByWindowBackground = false
    minSize = Self.mainMinSize
    let target: NSRect
    if let f = mainFrame, f.width >= Self.mainMinSize.width, f.height >= Self.mainMinSize.height {
      target = f
    } else {
      let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      let w = min(1160, visible.width - 80), h = min(740, visible.height - 80)
      target = NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
    }
    present(at: target)
  }

  // MARK: - Panel events → Dart

  func windowDidResignKey(_ notification: Notification) {
    guard !hidingOnPurpose, isVisible else { return }
    channel.invokeMethod("blur", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Closing the main window hides it; the app keeps living in the menu bar.
    hide()
    shape = .none
    channel.invokeMethod("closed", arguments: nil)
    return false
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    if shape == .main { mainFrame = frame }
  }

  // MARK: - Menu bar icon

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Džep")
      button.image?.isTemplate = true
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
  }

  @objc private func statusClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.addItem(withTitle: "Quick capture", action: #selector(menuPopup), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Open Džep", action: #selector(menuMain), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit Džep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      statusItem?.menu = menu
      statusItem?.button?.performClick(nil)
      statusItem?.menu = nil
    } else {
      channel.invokeMethod("togglePopup", arguments: nil)
    }
  }

  @objc private func menuPopup() { channel.invokeMethod("togglePopup", arguments: nil) }
  @objc private func menuMain() { channel.invokeMethod("openMain", arguments: nil) }
  @objc private func menuSettings() { channel.invokeMethod("openSettings", arguments: nil) }

  // MARK: - Global hotkey (Carbon: the one API that needs no Accessibility permission)

  private func setHotKey(keyCode: Int, modifiers: Int) -> Bool {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
    guard keyCode >= 0 else { return true }
    if hotKeyHandler == nil {
      var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let me = Unmanaged.passUnretained(self).toOpaque()
      InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
        guard let userData else { return noErr }
        let window = Unmanaged<MainFlutterWindow>.fromOpaque(userData).takeUnretainedValue()
        window.channel.invokeMethod("hotKey", arguments: nil)
        return noErr
      }, 1, &spec, me, &hotKeyHandler)
    }
    let id = EventHotKeyID(signature: OSType(0x4944_5250), id: 1)  // 'IDRP'
    let status = RegisterEventHotKey(
      UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    return status == noErr
  }
}
