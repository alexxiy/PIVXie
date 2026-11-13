import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // The Edit menu (MainMenu.xib) sends these, and they go to the focused
  // Flutter field (see MainFlutterWindow). When another window is in front,
  // such as a file panel, it gets AppKit's own action instead.
  @IBAction func flutterUndo(_ sender: Any?) { edit("undo", or: "undo:", sender) }
  @IBAction func flutterRedo(_ sender: Any?) { edit("redo", or: "redo:", sender) }
  @IBAction func flutterCut(_ sender: Any?) { edit("cut", or: "cut:", sender) }
  @IBAction func flutterCopy(_ sender: Any?) { edit("copy", or: "copy:", sender) }
  @IBAction func flutterPaste(_ sender: Any?) { edit("paste", or: "paste:", sender) }
  @IBAction func flutterPastePlain(_ sender: Any?) {
    edit("paste", or: "pasteAsPlainText:", sender)
  }
  @IBAction func flutterSelectAll(_ sender: Any?) {
    edit("selectAll", or: "selectAll:", sender)
  }

  private func edit(_ action: String, or standard: String, _ sender: Any?) {
    if let window = mainFlutterWindow as? MainFlutterWindow, NSApp.keyWindow === window {
      window.edit(action)
    } else {
      NSApp.sendAction(NSSelectorFromString(standard), to: nil, from: sender)
    }
  }
}
