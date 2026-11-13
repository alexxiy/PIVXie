import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// macOS: the Edit menu's Undo, Redo, Cut, Copy, Paste and Select All, and
/// a ⌘V that a clipboard manager or a dictation app posts. AppKit gives
/// those to a hidden text view that never passes them on to Flutter's
/// fields (flutter/flutter#184571), so the window sends them here instead
/// (macos/Runner/MainFlutterWindow.swift and AppDelegate.swift), and they
/// act on the focused field as the keys would.
const _editChannel = MethodChannel("PIVXIE_EDIT");

void listenToMacEditMenu() {
  if (!Platform.isMacOS) return;
  _editChannel.setMethodCallHandler(handleMacEdit);
}

@visibleForTesting
Future<void> handleMacEdit(MethodCall call) async {
  final context = primaryFocus?.context;
  final intent = macEditIntent(call.method);
  if (context != null && intent != null) {
    Actions.maybeInvoke(context, intent);
  }
}

/// The text editing intent for one of the window's actions.
@visibleForTesting
Intent? macEditIntent(String action) {
  const cause = SelectionChangedCause.keyboard;
  return switch (action) {
    "undo" => const UndoTextIntent(cause),
    "redo" => const RedoTextIntent(cause),
    "cut" => const CopySelectionTextIntent.cut(cause),
    "copy" => CopySelectionTextIntent.copy,
    "paste" => const PasteTextIntent(cause),
    "selectAll" => const SelectAllTextIntent(cause),
    _ => null,
  };
}
