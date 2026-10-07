import Foundation

/// What the app, its Siri intents and the widget extension share through the
/// App Group: the device token (written by lib/mobile.dart at sign-in), a
/// snapshot of open todos for the widget, and actions queued while offline
/// (the app replays them on next open). Compiled into Runner and DzepWidget,
/// the iPhone's and the Mac's (macos/Runner.xcodeproj; see the end).
enum DzepShared {
  static let defaults = UserDefaults(suiteName: "group.com.danyzmaj.dzep")!

  struct Todo: Codable, Hashable {
    let id: String
    let title: String
  }

  static var token: String? { defaults.string(forKey: "token") }

  static var todos: [Todo] {
    get { (try? JSONDecoder().decode([Todo].self, from: defaults.data(forKey: "todos") ?? Data())) ?? [] }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "todos") }
  }

  /// Actions for the app to replay (the iPhone's offline ones, every tick of
  /// the Mac's widget), as the JSON the `device` function takes.
  static func queue(_ action: [String: String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: action),
      let entry = String(data: data, encoding: .utf8)
    else { return }
    defaults.set((defaults.stringArray(forKey: "pending") ?? []) + [entry], forKey: "pending")
  }

  enum Outcome { case done, signedOut, failed }

  /// POST to the `device` edge function (see supabase/functions/device).
  static func send(_ action: [String: String]) async -> Outcome {
    guard let token else { return .signedOut }
    var request = URLRequest(url: URL(string: "https://tgqmhieundubwtyvsnih.supabase.co/functions/v1/device")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("sb_publishable_THRH7YNiM27mZTwXcWY7Rg_emvQ5ncw", forHTTPHeaderField: "apikey")
    request.setValue(token, forHTTPHeaderField: "x-dzep-token")
    request.httpBody = try? JSONSerialization.data(withJSONObject: action)
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return .failed }
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200, 201: return .done
    case 401: return .signedOut
    default: return .failed
    }
  }

  #if os(macOS)
    // The Mac's widget never calls the server: the menu-bar app is always
    // running and has the session. The widget queues its ticks and posts
    // `queued`; the app takes the queue at once (or on next launch).

    /// The open todos while signed in, nil while signed out (the Mac has no
    /// device token to tell).
    static var snapshot: [Todo]? {
      get { defaults.object(forKey: "todos") == nil ? nil : todos }
      set {
        if let newValue { todos = newValue } else { defaults.removeObject(forKey: "todos") }
      }
    }

    /// Darwin notification the widget posts after queueing a tick.
    static let queued = "group.com.danyzmaj.dzep.queued"
  #endif
}
