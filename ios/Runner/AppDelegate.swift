import Flutter
import UIKit

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
    // The iPhone half of lib/native.dart: only the device name is needed here.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IdejaNative")!
    let channel = FlutterMethodChannel(name: "ideja/native", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "deviceName":
        result(UIDevice.current.name)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
