import UIKit
import Flutter
import StoreKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    var flutter_native_splash = 1
    UIApplication.shared.isStatusBarHidden = false

    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "PivxieClipboard") {
      let clipboard = FlutterMethodChannel(
        name: "PIVXIE_CLIPBOARD",
        binaryMessenger: registrar.messenger()
      )
      clipboard.setMethodCallHandler { call, result in
        guard call.method == "setSecret",
          let args = call.arguments as? [String: Any],
          let text = args["text"] as? String
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        // A secret stays on this device (no Universal Clipboard) and is
        // gone after a while (a minute unless asked otherwise).
        let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 60
        UIPasteboard.general.setItems(
          [["public.utf8-plain-text": text]],
          options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(seconds),
          ]
        )
        result(nil)
      }
    }
    if let registrar = self.registrar(forPlugin: "PivxieStore") {
      let store = FlutterMethodChannel(
        name: "PIVXIE_STORE",
        binaryMessenger: registrar.messenger()
      )
      store.setMethodCallHandler { call, result in
        guard call.method == "requestReview" else {
          result(FlutterMethodNotImplemented)
          return
        }
        // The App Store's rating sheet; iOS decides whether it shows.
        guard
          let scene = UIApplication.shared.connectedScenes.first(where: {
            $0.activationState == .foregroundActive
          }) as? UIWindowScene
        else {
          result(false)
          return
        }
        if #available(iOS 16.0, *) {
          AppStore.requestReview(in: scene)
        } else {
          SKStoreReviewController.requestReview(in: scene)
        }
        result(true)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
