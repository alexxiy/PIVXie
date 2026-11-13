import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/mac_edit_menu.dart';

// The macOS Edit menu and posted ⌘V reach the focused field through
// handleMacEdit (the window's channel), not through AppKit.
void main() {
  var clipboard = "";

  setUp(() {
    clipboard = "";
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case "Clipboard.getData":
              return {"text": clipboard};
            case "Clipboard.setData":
              clipboard = (call.arguments as Map)["text"] as String;
              return null;
            case "Clipboard.hasStrings":
              return {"value": clipboard.isNotEmpty};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<TextEditingController> field(WidgetTester tester, String text) async {
    final controller = TextEditingController(text: text);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(controller: controller, autofocus: true),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> edit(WidgetTester tester, String action) async {
    await handleMacEdit(MethodCall(action));
    await tester.pumpAndSettle();
  }

  testWidgets("Paste puts the clipboard at the cursor", (tester) async {
    final controller = await field(tester, "IP ");
    controller.selection = const TextSelection.collapsed(offset: 3);
    clipboard = "203.0.113.5";
    await edit(tester, "paste");
    expect(controller.text, "IP 203.0.113.5");
  });

  testWidgets("Select All, Copy and Cut", (tester) async {
    final controller = await field(tester, "203.0.113.5");
    await edit(tester, "selectAll");
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 11),
    );
    await edit(tester, "copy");
    expect(clipboard, "203.0.113.5");
    expect(controller.text, "203.0.113.5");
    clipboard = "";
    await edit(tester, "cut");
    expect(clipboard, "203.0.113.5");
    expect(controller.text, "");
  });

  testWidgets("Undo takes a paste back, Redo puts it back", (tester) async {
    final controller = await field(tester, "");
    // The undo history takes changes in at most every half second.
    await tester.pump(const Duration(seconds: 1));
    clipboard = "203.0.113.5";
    await edit(tester, "paste");
    expect(controller.text, "203.0.113.5");
    await tester.pump(const Duration(seconds: 1));
    await edit(tester, "undo");
    expect(controller.text, "");
    await edit(tester, "redo");
    expect(controller.text, "203.0.113.5");
  });

  testWidgets("With no field focused nothing happens", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text("PIVXie")));
    clipboard = "203.0.113.5";
    await edit(tester, "paste");
    expect(find.text("PIVXie"), findsOneWidget);
  });

  test("Unknown actions have no intent", () {
    expect(macEditIntent("delete"), isNull);
    expect(macEditIntent("paste"), isA<PasteTextIntent>());
  });
}
