import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// How a new utterance interacts with whatever is currently being said.
enum SpeakMode {
  /// Stop current speech and say this now (user-initiated results).
  interrupt,

  /// Say this after current speech finishes.
  queue,

  /// Skip this if something is already being said (live announcements,
  /// so they never pile up behind each other).
  ifIdle,
}

/// Text-to-speech wrapper used by every module. Uses the phone's installed
/// TTS engine, which works offline once a voice is installed.
///
/// Prompts never overlap: [speak] resolves when the utterance has finished
/// (or was interrupted), so callers can safely start listening afterwards.
class Speaker {
  Speaker._();
  static final Speaker instance = Speaker._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _speaking = false;
  Future<void> _chain = Future.value();
  int _generation = 0;

  double _rate = 0.5;
  String lastSpoken = '';

  /// Called with each utterance so the UI can show captions.
  void Function(String text)? onCaption;

  double get rate => _rate;
  bool get isSpeaking => _speaking;

  Future<void> init({double rate = 0.5, String language = 'en-US'}) async {
    if (_initialized) return;
    _rate = rate;
    try {
      await _tts.setLanguage(language);
      await _tts.setSpeechRate(_rate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      // Duck other audio instead of pausing it.
      await _tts.setQueueMode(0);
    } catch (_) {}
    _initialized = true;
  }

  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.2, 0.9);
    await _tts.setSpeechRate(_rate);
  }

  /// Speaks [text]. See [SpeakMode] for how it treats ongoing speech.
  Future<void> speak(String text, {SpeakMode mode = SpeakMode.interrupt}) async {
    if (text.trim().isEmpty) return;
    await init();
    switch (mode) {
      case SpeakMode.ifIdle:
        if (_speaking) return;
        return _enqueue(text);
      case SpeakMode.queue:
        return _enqueue(text);
      case SpeakMode.interrupt:
        await stop();
        return _enqueue(text);
    }
  }

  Future<void> _enqueue(String text) {
    final gen = _generation;
    final next = _chain.then((_) async {
      if (gen != _generation) return; // cancelled by an interrupt
      _speaking = true;
      lastSpoken = text;
      onCaption?.call(text);
      try {
        await _tts.speak(text);
      } catch (_) {
      } finally {
        _speaking = false;
      }
    });
    _chain = next.catchError((_) {});
    return next;
  }

  Future<void> stop() async {
    _generation++;
    _chain = Future.value();
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> repeat() => speak(lastSpoken.isEmpty ? 'Nothing to repeat yet.' : lastSpoken);
}
