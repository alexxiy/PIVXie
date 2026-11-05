import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/global/prefs_provider.dart';
import '../utilities/assets.dart';
import '../utilities/logger.dart';
import 'adaptive_page.dart';

/// The PIVXie send animation, looping with rounded corners, shown while a
/// transaction is generated and sent. With "Sound effects" on its sound
/// loops along (mixed with other audio, silent in the device's silent
/// mode).
class TxSendAnimation extends ConsumerStatefulWidget {
  const TxSendAnimation({super.key, this.width});

  final double? width;

  @override
  ConsumerState<TxSendAnimation> createState() => _TxSendAnimationState();
}

class _TxSendAnimationState extends ConsumerState<TxSendAnimation> {
  AudioPlayer? _player;

  @override
  void initState() {
    super.initState();
    if (ref.read(prefsChangeNotifierProvider).soundEffects) {
      unawaited(_play(_player = AudioPlayer()));
    }
  }

  Future<void> _play(AudioPlayer player) async {
    try {
      await player.setAudioContext(
        AudioContextConfig(
          focus: AudioContextConfigFocus.mixWithOthers,
          respectSilence: true,
        ).build(),
      );
      await player.setReleaseMode(ReleaseMode.loop);
      // AssetSource paths are relative to "assets/".
      await player.play(
        AssetSource(Assets.persona.txSendSound.replaceFirst("assets/", "")),
      );
    } catch (e, s) {
      Logging.instance.w("Send sound failed", error: e, stackTrace: s);
    }
  }

  @override
  void dispose() {
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On a phone on its side the text and buttons below stay in sight.
    final short = ScreenFit.short(context);
    return Center(
      widthFactor: short ? null : 1,
      child: SizedBox(
        width: short ? MediaQuery.sizeOf(context).height * 0.7 : widget.width,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.asset(
              Assets.persona.txSend,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}
