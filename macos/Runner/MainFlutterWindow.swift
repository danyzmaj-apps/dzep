import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ServiceManagement

/// The app's only window. It takes two shapes, driven from Dart over the
/// `ideja/native` channel:
/// - **popup**: borderless, floating above everything (full-screen apps
///   included), on the screen under the mouse, no traffic lights.
/// - **main**: a normal titled window with a transparent, content-filled
///   title bar (Flutter draws the whole surface).
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var statusItem: NSStatusItem?
  private var mainFrame: NSRect?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    self.contentViewController = flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)

    channel = FlutterMethodChannel(
      name: "ideja/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    delegate = self
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    setupStatusItem()
    super.awakeFromNib()
    orderOut(nil)
  }

  // MARK: - Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "showPopup":
      showPopup(width: args["width"] as? Double ?? 680, height: args["height"] as? Double ?? 120)
      result(nil)
    case "resizePopup":
      resizePopup(height: args["height"] as? Double ?? 120)
      result(nil)
    case "showMain":
      showMain()
      result(nil)
    case "hide":
      orderOut(nil)
      // Hands focus back to whatever app was in front before the hotkey.
      NSApp.hide(nil)
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
    case "quit":
      NSApp.terminate(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func showPopup(width: Double, height: Double) {
    if styleMask.contains(.titled) { mainFrame = frame }
    styleMask = [.borderless, .fullSizeContentView]
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    hasShadow = true
    isMovable = false
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let top = visible.maxY - visible.height * 0.18
    setFrame(NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height), display: true)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func resizePopup(height: Double) {
    guard !styleMask.contains(.titled) else { return }
    var f = frame
    f.origin.y = f.maxY - height
    f.size.height = height
    setFrame(f, display: true)
    invalidateShadow()
  }

  private func showMain() {
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    level = .normal
    collectionBehavior = [.managed]
    isMovable = true
    isMovableByWindowBackground = false
    minSize = NSSize(width: 820, height: 480)
    if let f = mainFrame {
      setFrame(f, display: true)
    } else {
      let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
      let w = min(1160, visible.width - 80), h = min(740, visible.height - 80)
      setFrame(NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h), display: true)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  // MARK: - Window events → Dart

  func windowDidResignKey(_ notification: Notification) {
    channel.invokeMethod("blur", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Closing the main window hides it; the app keeps living in the menu bar.
    mainFrame = frame
    channel.invokeMethod("closed", arguments: nil)
    orderOut(nil)
    return false
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    if styleMask.contains(.titled) { mainFrame = frame }
  }

  // MARK: - Menu bar icon

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "Ideja")
      button.image?.isTemplate = true
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
      menu.addItem(withTitle: "Open Ideja", action: #selector(menuMain), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit Ideja", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
