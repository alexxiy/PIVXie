import Cocoa
import FlutterMacOS
import StoreKit

class MainFlutterWindow: NSWindow {
  /// Edit actions for the focused Flutter field
  /// (lib/utilities/mac_edit_menu.dart). AppKit would give the Edit menu's
  /// actions, and a ⌘V another app posts, to the hidden text view behind
  /// Flutter's text input, which never passes them on
  /// (flutter/flutter#184571).
  private var editChannel: FlutterMethodChannel?
  /// The Mac App Store's rating sheet (lib/services/app_updates.dart).
  private var storeChannel: FlutterMethodChannel?
  private var keyMonitor: Any?

  /// Whether this window saw a Command key go down. Apps that paste for
  /// you (clipboard managers, dictation, text expanders) post a ⌘V whose
  /// Command is only in the event's flags, and Flutter drops it.
  private var commandSeen = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    editChannel = FlutterMethodChannel(
      name: "PIVXIE_EDIT",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    storeChannel = FlutterMethodChannel(
      name: "PIVXIE_STORE",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    storeChannel?.setMethodCallHandler { [weak flutterViewController] call, result in
      guard call.method == "requestReview" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // macOS decides whether it shows.
      if #available(macOS 13.0, *), let controller = flutterViewController {
        AppStore.requestReview(in: controller)
      } else {
        SKStoreReviewController.requestReview()
      }
      result(true)
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      (self?.takePostedPaste(event) ?? false) ? nil : event
    }

    super.awakeFromNib()
  }

  deinit {
    if let keyMonitor = keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
  }

  override func becomeKey() {
    super.becomeKey()
    // A Command key held down in another window was never seen here.
    commandSeen = false
  }

  /// Sends [action] ("undo", "redo", "cut", "copy", "paste" or
  /// "selectAll") to the focused Flutter field.
  func edit(_ action: String) {
    editChannel?.invokeMethod(action, arguments: nil)
  }

  /// A ⌘V that another app posted: pasted through Flutter and kept from
  /// it. A real ⌘V (Command seen first) goes on to Flutter as usual.
  private func takePostedPaste(_ event: NSEvent) -> Bool {
    guard event.window === self else { return false }
    if event.type == .flagsChanged {
      commandSeen = event.modifierFlags.contains(.command)
      return false
    }
    guard event.modifierFlags.contains(.command), !commandSeen,
      event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v"
    else { return false }
    if event.type == .keyDown {
      edit("paste")
    }
    return true
  }
}
