import ActivityKit
import Flutter
import UIKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let reminders = Reminders()
  private let activities = OmpActivities()

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
    activities.channel = channel
    activities.install()
    channel.setMethodCallHandler { [reminders, activities, weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "setKeepAwake":
        UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
        result(nil)
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
      case "takeTappedSession":
        result(reminders.takeTappedSession())
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
      case "startActivity":
        activities.start(args, result: result)
      case "updateActivity":
        activities.update(args, result: result)
      case "endActivity":
        activities.end(args, result: result)
      case "liveActivities":
        result(activities.running())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// omp sessions on the Lock Screen and in the Dynamic Island
/// (ios/Shared/OmpActivity.swift, drawn by the widget extension). Dart
/// starts, updates and ends them while the app runs (lib/live_activity.dart);
/// otherwise the server updates them by push, at each one's push token,
/// which goes to Dart as `activityToken {key, token}`. One per session key.
final class OmpActivities {
  /// The app's channel, once its Flutter engine is up.
  var channel: FlutterMethodChannel?

  /// Push tokens by activity id. A token can come before Dart listens, so
  /// Dart also takes them with [running].
  private var tokens: [String: String] = [:]

  /// Activities whose token and state are followed.
  private var watched: Set<String> = []

  /// Pushes stop making sense after this long without one (the Mac asleep,
  /// or gone); the widget shows the activity as stale.
  private static let staleAfter: TimeInterval = 8 * 3600

  /// After a launch: the activities still running from before.
  func install() {
    for a in Activity<OmpActivity>.activities { watch(a) }
  }

  /// {key, token?} for each running activity.
  func running() -> [[String: Any]] {
    Activity<OmpActivity>.activities.filter { $0.activityState == .active }.map { a in
      var m: [String: Any] = ["key": a.attributes.key]
      if let token = tokens[a.id] { m["token"] = token }
      return m
    }
  }

  private func active(_ key: String) -> [Activity<OmpActivity>] {
    Activity<OmpActivity>.activities.filter { $0.attributes.key == key && $0.activityState == .active }
  }

  /// {state, kind?, since: ms since 1970}; nil for anything else.
  private func content(_ args: [String: Any]) -> ActivityContent<OmpActivity.ContentState>? {
    guard let raw = args["state"] as? String, let state = OmpActivity.ContentState.State(rawValue: raw) else {
      return nil
    }
    let since = (args["since"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    let kind = (args["kind"] as? String).flatMap(OmpActivity.ContentState.Kind.init(rawValue:))
    return ActivityContent(
      state: .init(state: state, since: since / 1000, kind: kind),
      staleDate: Date().addingTimeInterval(Self.staleAfter))
  }

  /// {key, title, project, state, kind?, since}: starts one for the session,
  /// or updates the one it has. true: running; false: Live Activities are
  /// off for Džep (Settings) or iOS refused.
  func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String, let content = content(args) else { return result(false) }
    if !active(key).isEmpty { return update(args, result: result) }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return result(false) }
    let attributes = OmpActivity(
      key: key, title: args["title"] as? String ?? "omp", project: args["project"] as? String ?? "")
    do {
      watch(try Activity.request(attributes: attributes, content: content, pushType: .token))
      result(true)
    } catch {
      NSLog("Džep: Live Activity: \(error)")
      result(false)
    }
  }

  /// {key, state, kind?, since}
  func update(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String, let content = content(args) else { return result(false) }
    let list = active(key)
    Task { @MainActor in
      for a in list { await a.update(content) }
      result(!list.isEmpty)
    }
  }

  /// {key, immediate?}: shows Ended, gone at once (the person ended it) or
  /// after 10 minutes (the session ended on the Mac).
  func end(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String else { return result(nil) }
    let list = active(key)
    let content = ActivityContent(
      state: OmpActivity.ContentState(state: .ended, since: Date().timeIntervalSince1970), staleDate: nil)
    let policy: ActivityUIDismissalPolicy =
      args["immediate"] as? Bool == true ? .immediate : .after(Date().addingTimeInterval(600))
    Task { @MainActor in
      for a in list { await a.end(content, dismissalPolicy: policy) }
      result(nil)
    }
  }

  private func watch(_ activity: Activity<OmpActivity>) {
    guard watched.insert(activity.id).inserted else { return }
    let key = activity.attributes.key
    let id = activity.id
    Task { @MainActor in
      for await data in activity.pushTokenUpdates {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.tokens[id] = token
        self.channel?.invokeMethod("activityToken", arguments: ["key": key, "token": token])
      }
    }
    Task { @MainActor in
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        // Ended here, by a push, or swiped away: its token is no use now.
        let token = self.tokens.removeValue(forKey: id)
        self.watched.remove(id)
        var args: [String: Any] = ["key": key]
        if let token { args["token"] = token }
        self.channel?.invokeMethod("activityEnded", arguments: args)
        break
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

  /// The same for a terminal push: the omp session it is about.
  private var tappedSession: String?

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

  func takeTappedSession() -> String? {
    defer { tappedSession = nil }
    return tappedSession
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
      let session = info["session"] as? String
      DispatchQueue.main.async {
        self.tappedSession = session
        self.channel?.invokeMethod("openTerminal", arguments: session.map { ["session": $0] })
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
