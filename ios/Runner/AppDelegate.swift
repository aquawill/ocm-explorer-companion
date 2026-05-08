import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(
        name: "com.example.RefApp/share_channel",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "shareFile":
          self?.shareFile(call: call, result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func shareFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String,
          !path.isEmpty else {
      result(FlutterError(code: "missing_path", message: "Missing file path.", details: nil))
      return
    }

    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "missing_file", message: "File does not exist: \(path)", details: nil))
      return
    }

    let fileUrl = URL(fileURLWithPath: path)
    let activityViewController = UIActivityViewController(
      activityItems: [fileUrl],
      applicationActivities: nil
    )
    if let popoverController = activityViewController.popoverPresentationController {
      popoverController.sourceView = window?.rootViewController?.view
      popoverController.sourceRect = window?.rootViewController?.view.bounds ?? .zero
    }
    window?.rootViewController?.present(activityViewController, animated: true) {
      result(nil)
    }
  }
}
