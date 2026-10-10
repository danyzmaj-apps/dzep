import ActivityKit
import Foundation

/// An omp session followed on the Lock Screen and in the Dynamic Island
/// (the app starts it: ios/Runner/AppDelegate.swift; the widget extension
/// draws it: ios/DzepWidget/DzepWidget.swift). iPhone only: the Mac targets
/// don't compile this file.
///
/// What it's called is fixed when it starts; pushes carry only the
/// ContentState. They can't carry text: the notification extension that
/// decrypts alerts never sees a Live Activity push, so anything in one
/// would be readable by the relay.
struct OmpActivity: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    enum State: String, Codable, Hashable {
      case working, needs, done, ended
    }

    /// What omp waits for, when it needs you.
    enum Kind: String, Codable, Hashable {
      case question, approval, plan
    }

    var state: State

    /// When it got into this state, in seconds since 1970. A plain number
    /// rather than a Date: ActivityKit decodes a pushed Date as seconds since
    /// 2001, which no server sends.
    var since: Double
    var kind: Kind?

    var sinceDate: Date { Date(timeIntervalSince1970: since) }
  }

  /// The session's key (`kitty-<pid>/<window id>` or `pid:<pid>`).
  var key: String
  var title: String
  var project: String

  /// Opens the session in the app (lib/mobile.dart).
  var link: URL {
    var c = URLComponents()
    c.scheme = "dzep"
    c.host = "session"
    c.queryItems = [URLQueryItem(name: "key", value: key)]
    return c.url!
  }
}
