import Flutter
import UIKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let reminders = Reminders()

  /// Waiting for APNs to hand over this iPhone's device token (registerPush).
  private var pushWaiter: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Before launch ends: the tap or Done that launched the app comes next.
    reminders.install()
    return launched
  }

  override func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushWaiter?(["token": token, "key": DzepShared.makePushKey().base64EncodedString()])
    pushWaiter = nil
  }

  override func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    pushWaiter?(nil)
    pushWaiter = nil
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The iPhone half of lib/native.dart: device name, the App Group the Siri
    // intents and the widget read (ios/Shared/DzepShared.swift), reminders.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DzepNative")!
    let channel = FlutterMethodChannel(name: "dzep/native", binaryMessenger: registrar.messenger())
    reminders.channel = channel
    channel.setMethodCallHandler { [reminders, weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "deviceName":
        result(UIDevice.current.name)
      case "setSharedToken":
        if let token = args["token"] as? String {
          DzepShared.defaults.set(token, forKey: "token")
        } else {
          DzepShared.defaults.removeObject(forKey: "token")
          DzepShared.todos = []
        }
        WidgetCenter.shared.reloadAllTimelines()
        result(nil)
      case "setSharedTodos":
        let todos = (args["todos"] as? [[String: String]] ?? []).compactMap { t -> DzepShared.Todo? in
          guard let id = t["id"], let title = t["title"] else { return nil }
          return DzepShared.Todo(id: id, title: title)
        }
        if todos != DzepShared.todos {
          DzepShared.todos = todos
          WidgetCenter.shared.reloadTimelines(ofKind: "DzepTodos")
        }
        result(nil)
      case "takePending":
        // Actions Siri or the widget couldn't send; the app replays them.
        let pending = DzepShared.defaults.stringArray(forKey: "pending") ?? []
        DzepShared.defaults.removeObject(forKey: "pending")
        result(pending)
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
        reminders.schedule(args["reminders"] as? [[String: Any]] ?? []) { result(nil) }
      case "takeTappedTodo":
        result(reminders.takeTapped())
      case "registerPush":
        // Permission first (a no-op after the first answer), then APNs. nil:
        // not allowed or no token (the app keeps local reminders then).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
          DispatchQueue.main.async {
            guard granted, let self else { return result(nil) }
            self.pushWaiter?(nil)
            self.pushWaiter = result
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Todo reminders as local notifications. Dart picks them (lib/remind.dart)
/// and hands over the whole set on every change. A tap opens the app on that
/// todo; Done ticks it off the way the Todos widget does, so it works with
/// the app closed (and the app replays it if the server can't be reached).
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
  /// The app's channel, once its Flutter engine is up.
  var channel: FlutterMethodChannel?

  /// The todo whose notification was tapped, until Dart takes it: a tap that
  /// launched the app arrives before Dart listens.
  private var tapped: String?

  func install() {
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
  func schedule(_ list: [[String: Any]], then done: @escaping () -> Void) {
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

  func takeTapped() -> String? {
    defer { tapped = nil }
    return tapped
  }

  /// A reminder going off while Džep is open still shows.
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
    // A push carries its todo in userInfo (DzepPush); a local reminder is
    // identified by it.
    let info = response.notification.request.content.userInfo
    let id = info["todo"] as? String ?? response.notification.request.identifier
    if info["kind"] as? String == "terminal" {
      DispatchQueue.main.async {
        self.channel?.invokeMethod("openTerminal", arguments: nil)
        completionHandler()
      }
      return
    }
    switch response.actionIdentifier {
    case "done":
      DzepShared.todos.removeAll { $0.id == id }
      WidgetCenter.shared.reloadTimelines(ofKind: "DzepTodos")
      let action = ["action": "done", "id": id]
      Task {
        if await DzepShared.send(action) == .failed {
          DzepShared.queue(action)
          // Running: the app replays it now instead of at its next start.
          await MainActor.run { self.channel?.invokeMethod("pending", arguments: nil) }
        }
        completionHandler()
      }
    case UNNotificationDefaultActionIdentifier:
      DispatchQueue.main.async {
        self.tapped = id
        self.channel?.invokeMethod("openTodo", arguments: ["id": id])
        completionHandler()
      }
    default:
      completionHandler()
    }
  }
}
