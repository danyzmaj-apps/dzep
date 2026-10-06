import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The iPhone half of lib/native.dart: device name, and the App Group the
    // Siri intents and the widget read (ios/Shared/DzepShared.swift).
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DzepNative")!
    let channel = FlutterMethodChannel(name: "dzep/native", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
