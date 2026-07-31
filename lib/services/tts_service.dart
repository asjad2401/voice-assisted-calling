import 'package:flutter_tts/flutter_tts.dart';

/// Service that wraps flutter_tts with a "speak and wait" pattern.
/// For a voice-first app for blind/low-vision users, prompts must never overlap
/// or get garbled — every spoken message should finish before listening,
/// while also supporting immediate cancellation on high-priority user interaction.
class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.48); // Slightly slower than default for maximum voice clarity
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _initialized = true;
  }

  /// Speaks [text] and resolves when speech finishes or is stopped.
  Future<void> speak(String text) async {
    await init();
    await _tts.stop(); // Stop any leftover speech before starting
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(text);
  }

  /// Immediately stops any ongoing speech output.
  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
  }
}
