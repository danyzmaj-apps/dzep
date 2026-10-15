import Carbon.HIToolbox
import Sparkle
import Cocoa
import FlutterMacOS
import ServiceManagement
import UserNotifications
import WidgetKit
import notify

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

/// The note window: one note, apart from the app, floating over everything
/// so it can sit beside whatever else is on screen, moved and resized at
/// will. Non-activating like the popup: it takes the keyboard without
/// pulling Džep (and its menu bar) in front of the app beside it.
final class NotePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  // Esc is the editor's; a panel would otherwise close itself behind Dart's
  // back.
  override func cancelOperation(_ sender: Any?) {}
  // ⌘W closes it even with the editor focused, as in the main window.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// The main window, from MainMenu.xib: a regular window, so it behaves like
/// any app's — while it's open Džep has a Dock icon and its menu bar, ⌘W
/// closes it, ⌘Q quits. Closed, Džep goes back to living in the menu bar.
///
/// It also owns the Flutter engine, which runs in multi-view mode: one Dart
/// app (one store, one sync) draws this window, the popup panel and the note
/// window. Separate windows means none is ever resized to become another
/// (Flutter blocks after resizes and Impeller crashes on rapid ones).
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var popup: PopupPanel!
  private var note: NotePanel!
  private var popupController: FlutterViewController!
  private var mainController: FlutterViewController!
  private var noteController: FlutterViewController!
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var statusItem: NSStatusItem?

  /// Set while Džep hides the popup itself, so that isn't reported to Dart as
  /// the user clicking away ("blur").
  private var hidingPopup = false

  /// The window that had the keyboard when the popup opened (the main
  /// window or the note window): it gets it back when the popup goes.
  private weak var keyBeforePopup: NSWindow?

  static let popupSize = NSSize(width: 720, height: 660)
  static let noteSize = NSSize(width: 340, height: 380)

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
    // The desktop widget (macos/DzepWidget) queues its ticks in the App Group
    // and posts this; Dart then takes the queue ("takePending").
    var widgetTicks: Int32 = 0
    notify_register_dispatch(DzepShared.queued, &widgetTicks, .main) { [weak self] _ in
      self?.channel.invokeMethod("pending", arguments: nil)
    }
    // Now, before launch ends: a reminder click that launched Džep comes in
    // right after.
    setUpReminders()
    engine.run(withEntrypoint: nil)

    popupController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    popupController.backgroundColor = .clear
    mainController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    mainController.backgroundColor = NSColor(red: 0.09, green: 0.094, blue: 0.114, alpha: 1)
    noteController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    noteController.backgroundColor = mainController.backgroundColor

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

    note = NotePanel(
      contentRect: NSRect(origin: .zero, size: Self.noteSize),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false)
    note.contentViewController = noteController
    note.setContentSize(Self.noteSize)
    note.titleVisibility = .hidden
    note.titlebarAppearsTransparent = true
    note.standardWindowButton(.miniaturizeButton)?.isHidden = true
    note.standardWindowButton(.zoomButton)?.isHidden = true
    note.contentMinSize = NSSize(width: 200, height: 120)
    note.level = .floating
    // Shown over a full-screen app too, on the Space it's opened in.
    note.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    note.hidesOnDeactivate = false
    note.becomesKeyOnlyIfNeeded = false
    note.isReleasedWhenClosed = false
    note.delegate = self
    let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    note.setFrameOrigin(NSPoint(x: screen.maxX - note.frame.width - 24, y: screen.maxY - note.frame.height - 24))
    note.setFrameAutosaveName("DzepNote")  // where you last put it, and its size

    contentViewController = mainController
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    // Down to a narrow strip beside something else; the layout folds its
    // sidebar into icons (lib/main_window.dart).
    minSize = NSSize(width: 480, height: 360)
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
      result([
        "popup": popupController.viewIdentifier, "main": mainController.viewIdentifier,
        "note": noteController.viewIdentifier,
      ])
    case "showPopup":
      showPopup()
      result(nil)
    case "hidePopup":
      hidePopup()
      result(nil)
    case "showMain":
      showMain()
      result(nil)
    case "showNote":
      showNote(hideMain: args["hideMain"] as? Bool ?? false)
      result(nil)
    case "hideNote":
      note.orderOut(nil)
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
      // Whichever window the drag began in: the main one or the note.
      if let event = NSApp.currentEvent, let window = event.window { window.performDrag(with: event) }
      result(nil)
    case "setTodoCount":
      // The pocket icon then "3" in the menu bar: open todos at a glance.
      let count = args["count"] as? Int ?? 0
      statusItem?.button?.title = count > 0 ? " \(count)" : ""
      result(nil)
    case "idleSeconds":
      result(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!))
    case "setSharedTodos":
      // The desktop widget's snapshot (macos/DzepWidget); null once signed out.
      let todos = (args["todos"] as? [[String: String]])?.compactMap { t -> DzepShared.Todo? in
        guard let id = t["id"], let title = t["title"] else { return nil }
        return DzepShared.Todo(id: id, title: title)
      }
      if todos != DzepShared.snapshot {
        DzepShared.snapshot = todos
        WidgetCenter.shared.reloadAllTimelines()
      }
      result(nil)
    case "takePending":
      // Todos ticked off in the widget, for Dart to apply.
      result(DzepShared.takePending())
    case "getBackend":
      result(DzepShared.backend.map { ["url": $0.url, "key": $0.key] })
    case "setBackend":
      if let url = args["url"] as? String, let key = args["key"] as? String {
        DzepShared.backend = DzepShared.Backend(url: url, key: key)
      } else {
        DzepShared.backend = nil
      }
      result(nil)
    case "setReminders":
      setReminders(args["reminders"] as? [[String: Any]] ?? []) { result(nil) }
    case "quit":
      NSApp.terminate(nil)
      result(nil)
    case "pickFolders":
      // Settings → Project folders → Add folder…; a sheet on this (the main) window.
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = true
      panel.canCreateDirectories = true
      panel.message = "Folders that hold your projects"
      panel.prompt = "Add"
      panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      panel.beginSheetModal(for: self) { response in
        result(response == .OK ? panel.urls.map { $0.path } : [])
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Džep is quitting: Dart takes its address out of cli.json (lib/local_api.dart)
  /// so the terminal's integrations stop calling a port nobody owns now.
  /// [done] runs once Dart has, or after a second at most.
  func quitting(_ done: @escaping () -> Void) {
    var finished = false
    let finish = {
      if finished { return }
      finished = true
      done()
    }
    channel.invokeMethod("quitting", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
  }

  private func showPopup() {
    // Not when the popup comes back after its own file dialog: neither
    // window was key then, but one was when the popup first opened.
    if !popup.isVisible {
      keyBeforePopup = isKeyWindow && NSApp.isActive ? self : note.isKeyWindow ? note : nil
    }
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

  /// Hides the popup; the main window or the note window takes the keyboard
  /// back if it had it before. Without this, how it was closed decided where
  /// the keys went: after Esc AppKit made the main window key again, after
  /// the hotkey it handed them to the app used before Džep. Not when the
  /// popup closed because the user clicked somewhere else (it isn't key
  /// anymore then).
  private func hidePopup() {
    let back = popup.isKeyWindow && keyBeforePopup?.isVisible == true ? keyBeforePopup : nil
    keyBeforePopup = nil
    hidingPopup = true
    // Key first, so the popup going away never leaves Džep without a key
    // window.
    back?.makeKeyAndOrderFront(nil)
    popup.orderOut(nil)
    hidingPopup = false
    // The note window doesn't activate Džep; the main window does.
    if back === self { activate() }
  }

  /// [hideMain]: opened from the main window, which gives way to it until
  /// the note window closes. Džep stays a regular app meanwhile (its Dock
  /// icon brings the main window back): switching to .accessory would
  /// deactivate it, and the note window would lose the keyboard with it.
  private func showNote(hideMain: Bool) {
    if hideMain { orderOut(nil) }
    note.orderFrontRegardless()
    note.makeKey()
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
    let window = notification.object as? NSWindow
    // Dart can't tell which window has the keyboard (the views share one
    // FocusManager); the main window takes the focus back once the note
    // window lets go of it.
    if window === note { channel.invokeMethod("noteKey", arguments: ["key": false]) }
    // The popup losing focus is the user clicking elsewhere: it closes.
    guard window === popup, !hidingPopup, popup.isVisible else { return }
    channel.invokeMethod("blur", arguments: nil)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === note { channel.invokeMethod("noteKey", arguments: ["key": true]) }
    // The Flutter views share one text input view, which moves to the
    // window with the focused field; the window it left is then its own
    // first responder, and keys would go nowhere (⌘F to the menu) until a
    // click. The Flutter view takes them instead.
    let controller = window === self ? mainController : window === note ? noteController : nil
    guard let controller, window.firstResponder === window,
      let view = controller.view.subviews.first(where: { $0.acceptsFirstResponder })
    else { return }
    window.makeFirstResponder(view)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // The note window's red button / ⌘W: Dart closes it (and brings the main
    // window back if it gave way to it).
    if sender === note {
      channel.invokeMethod("closeNote", arguments: nil)
      return false
    }
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
      button.image = Self.pocketIcon()
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
  }

  /// The menu bar mark: the app icon's pocket with a note tucked in, drawn
  /// as a template so macOS tints it for light and dark menu bars.
  private static func pocketIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      // The note, tilted, behind the pocket.
      NSGraphicsContext.saveGraphicsState()
      let tilt = NSAffineTransform()
      tilt.translateX(by: 9.6, yBy: 11.6)
      tilt.rotate(byDegrees: -9)
      tilt.concat()
      NSColor.black.setFill()
      NSBezierPath(roundedRect: NSRect(x: -3.6, y: -3, width: 7.2, height: 6.6), xRadius: 1, yRadius: 1).fill()
      NSGraphicsContext.restoreGraphicsState()

      let pocket = NSBezierPath()
      pocket.move(to: NSPoint(x: 3, y: 10.6))
      pocket.line(to: NSPoint(x: 15, y: 10.6))
      pocket.line(to: NSPoint(x: 15, y: 5.4))
      pocket.line(to: NSPoint(x: 9, y: 1.8))
      pocket.line(to: NSPoint(x: 3, y: 5.4))
      pocket.close()
      pocket.lineJoinStyle = .round
      // Hollow pocket: clears the note where the pocket covers it.
      NSGraphicsContext.current?.compositingOperation = .clear
      pocket.fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      pocket.lineWidth = 1.5
      pocket.stroke()
      let hem = NSBezierPath()
      hem.move(to: NSPoint(x: 4.5, y: 8.6))
      hem.line(to: NSPoint(x: 13.5, y: 8.6))
      hem.lineWidth = 1
      hem.setLineDash([1.4, 1.2], count: 2, phase: 0)
      hem.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Džep"
    return image
  }

  @objc private func statusClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.addItem(withTitle: "Quick capture", action: #selector(menuPopup), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Open Džep", action: #selector(menuMain), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
      menu.addItem(
        withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
      ).target = AppDelegate.updater
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

// MARK: - Todo reminders

/// Local notifications for todo reminders. Dart picks them (packages/dzep_core/lib/remind.dart)
/// and hands over the whole set on every change; a click opens that todo in
/// the main window, Done ticks it off through the desktop widget's queue (so
/// a click that launched Džep is applied once the store is open).
extension MainFlutterWindow: UNUserNotificationCenterDelegate {
  fileprivate func setUpReminders() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let done = UNNotificationAction(identifier: "done", title: "Done", options: [])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: "todo", actions: [done], intentIdentifiers: [], options: [])
    ])
  }

  /// Replaces every pending reminder with `list` ({id, title, at: ms since
  /// 1970}); the identifier is the todo's id. A non-empty set asks for
  /// permission first, which only prompts the first time.
  fileprivate func setReminders(_ list: [[String: Any]], then done: @escaping () -> Void) {
    let center = UNUserNotificationCenter.current()
    center.removeAllPendingNotificationRequests()
    guard !list.isEmpty else { return done() }
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      let added = DispatchGroup()
      for r in granted ? list : [] {
        guard let id = r["id"] as? String, let title = r["title"] as? String, let at = r["at"] as? Int else { continue }
        let content = UNMutableNotificationContent()
        content.body = title
        content.sound = .default
        content.categoryIdentifier = "todo"
        let wait = Date(timeIntervalSince1970: Double(at) / 1000).timeIntervalSinceNow
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, wait), repeats: false)
        added.enter()
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { _ in added.leave() }
      }
      added.notify(queue: .main, execute: done)
    }
  }

  /// A reminder going off while Džep is frontmost still shows.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.identifier
    let action = response.actionIdentifier
    DispatchQueue.main.async {
      if action == "done" {
        DzepShared.queue(["action": "done", "id": id])
        self.channel.invokeMethod("pending", arguments: nil)
      } else if action == UNNotificationDefaultActionIdentifier {
        self.channel.invokeMethod("openTodo", arguments: ["id": id])
      }
      completionHandler()
    }
  }
}
