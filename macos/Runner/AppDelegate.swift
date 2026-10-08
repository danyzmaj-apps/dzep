import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  /// Sparkle, checking the GitHub releases' appcast (Info.plist SUFeedURL).
  /// Not in debug builds: those aren't signed for updating.
  static let updater: SPUStandardUpdaterController = {
    #if DEBUG
      let start = false
    #else
      let start = true
    #endif
    return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
  }()

  // Menu-bar app until the main window opens (it switches to .regular then):
  // no Dock icon or menu bar at launch.
  override func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    // The template menu has no Close item; ⌘W should close the main window.
    let file = NSMenuItem()
    file.submenu = NSMenu(title: "File")
    file.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    NSApp.mainMenu?.insertItem(file, at: 1)
    // Preferences… (⌘,) opens Džep's settings.
    let window = NSApp.windows.first { $0 is MainFlutterWindow } as? MainFlutterWindow
    let appMenu = NSApp.mainMenu?.items.first?.submenu
    if let prefs = appMenu?.items.first(where: { $0.keyEquivalent == "," }) {
      prefs.target = window
      prefs.action = #selector(MainFlutterWindow.openSettingsFromMenu)
    }
    // Džep → Check for Updates…, right under About.
    let updates = NSMenuItem(
      title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: "")
    updates.target = Self.updater
    appMenu?.insertItem(updates, at: 1)
  }

  // Closing the main window never quits; Džep stays in the menu bar.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked (or the LaunchServices activation the main window asks
  // for): bring the main window back, unless it's already showing.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let window = mainWindow, !window.isVisible { window.reopen() }
    return true
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    mainWindow?.becameActive()
  }

  private var mainWindow: MainFlutterWindow? {
    NSApp.windows.first { $0 is MainFlutterWindow } as? MainFlutterWindow
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
