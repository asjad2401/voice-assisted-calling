import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech-to-text wrapper.
///
/// Recognition is requested *on device* first so it works without internet
/// (Android 12+ with the offline English pack installed via the Google app
/// / "Speech Recognition & Synthesis" settings). If the device has no
/// offline recognizer the standard recognizer is used, which on most
/// phones still runs offline when a language pack is downloaded.
class SpeechInput {
  SpeechInput._();
  static final SpeechInput instance = SpeechInput._();

  final SpeechToText _stt = SpeechToText();
  bool _available = false;
  bool _onDeviceWorks = true;
  bool _isListening = false;
  void Function(SpeechRecognitionError e)? _errorHook;

  bool get isListening => _isListening;
  bool get available => _available;

  /// False once the on-device recognizer reported it is unavailable.
  bool get usingOnDevice => _onDeviceWorks;

  Future<bool> init() async {
    if (_available) return true;
    try {
      _available = await _stt.initialize(
        onError: (e) {
          _isListening = false;
          _errorHook?.call(e);
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _isListening = false;
        },
      );
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  SpeechListenOptions _options(
          {required bool partial, required ListenMode mode, Duration? listenFor, Duration? pauseFor}) =>
      SpeechListenOptions(
        listenMode: mode,
        cancelOnError: true,
        partialResults: partial,
        onDevice: _onDeviceWorks,
        listenFor: listenFor,
        pauseFor: pauseFor,
      );

  bool _isOnDeviceFailure(SpeechRecognitionError e) {
    final m = e.errorMsg.toLowerCase();
    return m.contains('language_unavailable') ||
        m.contains('language_not_supported') ||
        m.contains('server') ||
        m.contains('network');
  }

  /// Listens for one utterance and returns the recognized text, or null.
  Future<String?> listenOnce({
    Duration timeout = const Duration(seconds: 8),
    Duration pauseFor = const Duration(seconds: 2, milliseconds: 500),
  }) async {
    final r = await _listenOnceInner(timeout, pauseFor);
    if (r.$2 && _onDeviceWorks) {
      // On-device recognizer is not installed: fall back once and remember.
      _onDeviceWorks = false;
      return (await _listenOnceInner(timeout, pauseFor)).$1;
    }
    return r.$1;
  }

  Future<(String?, bool)> _listenOnceInner(Duration timeout, Duration pauseFor) async {
    if (!await init()) return (null, false);
    if (_isListening) await cancel();
    String? best;
    bool onDeviceFailed = false;
    final done = Completer<void>();
    _errorHook = (e) {
      if (_isOnDeviceFailure(e)) onDeviceFailed = true;
      if (!done.isCompleted) done.complete();
    };
    _isListening = true;
    try {
      await _stt.listen(
        onResult: (res) {
          if (res.recognizedWords.isNotEmpty) best = res.recognizedWords;
          if (res.finalResult && !done.isCompleted) done.complete();
        },
        listenOptions: _options(partial: true, mode: ListenMode.confirmation, listenFor: timeout, pauseFor: pauseFor),
      );
      await done.future.timeout(timeout + const Duration(seconds: 1), onTimeout: () {});
    } catch (_) {
    } finally {
      _errorHook = null;
      await stop();
    }
    final text = best?.trim();
    return ((text == null || text.isEmpty) ? null : text, onDeviceFailed && best == null);
  }

  /// Streams partial results and calls [onMatched] with the first keyword
  /// group that appears, e.g. {'answer': [...], 'ignore': [...]}.
  Future<void> listenForKeywords({
    required Map<String, List<String>> groups,
    required void Function(String group) onMatched,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await init()) return;
    if (_isListening) await cancel();
    _isListening = true;
    bool fired = false;
    try {
      await _stt.listen(
        onResult: (res) {
          if (fired) return;
          final words = ' ${res.recognizedWords.toLowerCase()} ';
          for (final g in groups.entries) {
            if (g.value.any((k) => words.contains(' $k '))) {
              fired = true;
              cancel();
              onMatched(g.key);
              return;
            }
          }
        },
        listenOptions: _options(
          partial: true,
          mode: ListenMode.dictation,
          listenFor: timeout,
          pauseFor: const Duration(seconds: 8),
        ),
      );
    } catch (_) {
      _isListening = false;
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

/// True if [text] sounds like agreement.
bool isAffirmative(String? text) {
  if (text == null) return false;
  final t = ' ${text.toLowerCase()} ';
  const yes = [
    'yes',
    'yeah',
    'yep',
    'sure',
    'ok',
    'okay',
    'correct',
    'right',
    'do it',
    'go ahead',
    'confirm',
    'haan',
    'ji'
  ];
  const no = [' no ', 'nope', 'not ', "don't", 'cancel', 'stop'];
  if (no.any(t.contains)) return false;
  return yes.any((w) => t.contains(' $w ') || t.contains(' $w'));
}
