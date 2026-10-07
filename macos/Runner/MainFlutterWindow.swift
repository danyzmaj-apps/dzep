import Carbon.HIToolbox
import Cocoa
import FlutterMacOS
import ServiceManagement

/// The ⇧⌘Space capture panel, Raycast-style: it takes the keyboard without
/// activating Džep (`.nonactivatingPanel`, which AppKit only honours when a
/// window is created with it), floats over everything, and never changes
/// size — Flutter draws and animates the panel inside it.
final class PopupPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  // Esc belongs to Dart (it may only close the description field); a panel
  // would otherwise close itself behind Dart's back.
  override func cancelOperation(_ sender: Any?) {}
}

/// The main window, from MainMenu.xib: a regular window, so it behaves like
/// any app's — while it's open Džep has a Dock icon and its menu bar, ⌘W
/// closes it, ⌘Q quits. Closed, Džep goes back to living in the menu bar.
///
/// It also owns the Flutter engine, which runs in multi-view mode: one Dart
/// app (one store, one sync) draws both this window and the popup panel.
/// Separate windows means neither is ever resized to become the other (Flutter
/// blocks after resizes and Impeller crashes on rapid ones).
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var popup: PopupPanel!
  private var popupController: FlutterViewController!
  private var mainController: FlutterViewController!
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var statusItem: NSStatusItem?

  /// Set while Džep hides the popup itself, so that isn't reported to Dart as
  /// the user clicking away ("blur").
  private var hidingPopup = false

  static let popupSize = NSSize(width: 720, height: 660)

  override func awakeFromNib() {
    // Headless start, then the two views: in multi-view mode the engine can
    // only accept views once it's running.
    let engine = FlutterEngine(name: "dzep", project: nil, allowHeadlessExecution: true)
    // Private: the switch Flutter's own (experimental) multi-window API flips.
    // Must happen before any view controller attaches to the engine.
    let enableMultiView = Selector(("enableMultiView"))
    if engine.responds(to: enableMultiView) { engine.perform(enableMultiView) }
    RegisterGeneratedPlugins(registry: engine)
    channel = FlutterMethodChannel(name: "dzep/native", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    engine.run(withEntrypoint: nil)

    popupController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    popupController.backgroundColor = .clear
    mainController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    mainController.backgroundColor = NSColor(red: 0.09, green: 0.094, blue: 0.114, alpha: 1)

    popup = PopupPanel(
      contentRect: NSRect(origin: .zero, size: Self.popupSize),
      styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    popup.contentViewController = popupController
    popup.setContentSize(Self.popupSize)  // assigning the controller shrank it to the view
    popup.isOpaque = false
    popup.backgroundColor = .clear
    popup.hasShadow = false  // Flutter draws the panel's shadow
    popup.level = .floating
    popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    popup.hidesOnDeactivate = false
    popup.becomesKeyOnlyIfNeeded = false
    popup.isReleasedWhenClosed = false
    popup.isMovable = false
    popup.delegate = self

    contentViewController = mainController
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    minSize = NSSize(width: 820, height: 480)
    let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let w = min(1160, visible.width - 80), h = min(740, visible.height - 80)
    setFrame(NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h), display: false)
    setFrameAutosaveName("DzepMain")  // remembers where you put it
    isReleasedWhenClosed = false
    delegate = self

    setupStatusItem()
    super.awakeFromNib()
  }

  // MARK: - Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "viewIds":
      result(["popup": popupController.viewIdentifier, "main": mainController.viewIdentifier])
    case "showPopup":
      showPopup()
      result(nil)
    case "hidePopup":
      hidingPopup = true
      popup.orderOut(nil)
      hidingPopup = false
      result(nil)
    case "showMain":
      showMain()
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

  private func showPopup() {
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let top = visible.maxY - visible.height * 0.18
    let size = Self.popupSize
    // Same size every time: a move, never a resize.
    popup.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
    popup.orderFrontRegardless()
    popup.makeKey()
    resumeFlutter()
  }

  private func showMain() {
    // A real app while the window is open: Dock icon, menu bar, ⌘-Tab.
    NSApp.setActivationPolicy(.regular)
    makeKeyAndOrderFront(nil)
    resumeFlutter()
    activate()
  }

  /// Makes Džep the active app, so the menu bar, ⌘W and ⌘Q are Džep's.
  ///
  /// Since macOS 14 `NSApp.activate()` is only a request, and macOS turns it
  /// down when the user's last input went to another app — which is the case
  /// after "3" in the popup, since the popup deliberately doesn't activate
  /// Džep. Opening the app through LaunchServices (what the Dock and `open -a`
  /// do) is always honoured, so that's the fallback.
  private func activate() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard !NSApp.isActive else { return }
      let config = NSWorkspace.OpenConfiguration()
      config.activates = true
      NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }
  }

  /// Once Džep really is active, the main window (if open) takes the keyboard.
  func becameActive() {
    if isVisible { makeKeyAndOrderFront(nil) }
  }

  /// Flutter's engine only draws while it believes the app is visible, which
  /// it reads from NSApplication's occlusion state — not updated when only a
  /// non-activating panel comes on screen. Džep knows a window just appeared.
  private func resumeFlutter() {
    popupController.engine.binaryMessenger.send(
      onChannel: "flutter/lifecycle", message: "AppLifecycleState.resumed".data(using: .utf8))
  }

  /// App menu → Preferences… (⌘,).
  @objc func openSettingsFromMenu() {
    channel.invokeMethod("openSettings", arguments: nil)
  }

  /// Dock icon clicked while Džep runs (AppDelegate).
  func reopen() {
    channel.invokeMethod("openMain", arguments: nil)
  }

  // MARK: - Window events → Dart

  func windowDidResignKey(_ notification: Notification) {
    // The popup losing focus is the user clicking elsewhere: it closes.
    guard notification.object as? NSWindow === popup, !hidingPopup, popup.isVisible else { return }
    channel.invokeMethod("blur", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === self else { return true }
    // ⌘W / the red button: hide (the window is reused), back to the menu bar.
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    channel.invokeMethod("mainClosed", arguments: nil)
    return false
  }

  /// ⌘W hides the main window like in any Mac app. Caught here, before the
  /// Flutter view: a focused text field otherwise keeps the keystroke and it
  /// never reaches the File menu.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
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
