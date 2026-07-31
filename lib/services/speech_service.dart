import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps speech_to_text with single-shot listening and continuous keyword streaming
/// for fast, reliable voice recognition during incoming calls and dialing.
class SpeechService {
  SpeechService._internal();
  static final SpeechService instance = SpeechService._internal();

  final SpeechToText _stt = SpeechToText();
  bool _available = false;
  bool _isListening = false;

  bool get isListening => _isListening;

  Future<bool> init() async {
    try {
      _available = await _stt.initialize(
        onError: (e) {
          _isListening = false;
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            _isListening = false;
          }
        },
      );
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  /// Listens for keyword matches in partial speech recognition results in real-time.
  /// Fires [onMatched] as soon as any word in [answerKeywords] or [ignoreKeywords] is detected.
  Future<void> listenForKeywords({
    required List<String> answerKeywords,
    required List<String> ignoreKeywords,
    required Function(String matchedType) onMatched,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_available) {
      final ok = await init();
      if (!ok) return;
    }

    if (_isListening) {
      await cancel();
    }

    _isListening = true;

    try {
      await _stt.listen(
        onResult: (result) {
          final words = result.recognizedWords.toLowerCase().trim();
          if (words.isEmpty) return;

          for (final kw in answerKeywords) {
            if (words.contains(kw)) {
              _isListening = false;
              cancel();
              onMatched('answer');
              return;
            }
          }

          for (final kw in ignoreKeywords) {
            if (words.contains(kw)) {
              _isListening = false;
              cancel();
              onMatched('ignore');
              return;
            }
          }
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          partialResults: true,
        ),
        listenFor: timeout,
        pauseFor: const Duration(seconds: 10),
      );
    } catch (e) {
      _isListening = false;
    }
  }

  /// Listens for a single utterance and returns the recognized text,
  /// or null if nothing usable was captured within [timeout].
  Future<String?> listenOnce({
    Duration timeout = const Duration(seconds: 10),
    Duration pauseFor = const Duration(seconds: 3, milliseconds: 500),
  }) async {
    if (!_available) {
      final ok = await init();
      if (!ok) return null;
    }

    // Stop any active listening session first
    if (_isListening) {
      await cancel();
    }

    String? finalResult;
    final completer = Completer<String?>();
    _isListening = true;

    try {
      await _stt.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            finalResult = result.recognizedWords;
          }
          if (result.finalResult || (result.recognizedWords.trim().length >= 2 && !_stt.isListening)) {
            _isListening = false;
            if (!completer.isCompleted) {
              completer.complete(finalResult);
            }
          }
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.confirmation,
          cancelOnError: false,
          partialResults: true,
        ),
        listenFor: timeout,
        pauseFor: pauseFor,
      );

      final result = await completer.future.timeout(
        timeout + const Duration(seconds: 1),
        onTimeout: () {
          _isListening = false;
          return finalResult;
        },
      );

      await stop();
      return (result == null || result.trim().isEmpty) ? null : result.trim();
    } catch (e) {
      _isListening = false;
      await stop();
      return null;
    }
  }

  Future<void> stop() async {
    _isListening = false;
    try {
      await _stt.stop();
    } catch (_) {}
  }

  Future<void> cancel() async {
    _isListening = false;
    try {
      await _stt.cancel();
    } catch (_) {}
  }
}
