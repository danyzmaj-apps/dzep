import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
    if let prefs = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }) {
      prefs.target = window
      prefs.action = #selector(MainFlutterWindow.openSettingsFromMenu)
    }
  }

  // Closing the main window never quits; Džep stays in the menu bar.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked: bring the main window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    (NSApp.windows.first { $0 is MainFlutterWindow } as? MainFlutterWindow)?.reopen()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
