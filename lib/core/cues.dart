import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Haptic and audio cues. Every cue is non-verbal so it never competes
/// with speech for attention.
class Cues {
  Cues._();
  static final Cues instance = Cues._();

  static const _device = MethodChannel('vision_assist/device');
  bool hapticsEnabled = true;
  bool? _hasVibrator;

  Future<void> _vibrate({int duration = 60, List<int>? pattern, List<int>? intensities}) async {
    if (!hapticsEnabled) return;
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator != true) return;
    if (pattern != null) {
      await Vibration.vibrate(pattern: pattern, intensities: intensities ?? const []);
    } else {
      await Vibration.vibrate(duration: duration);
    }
  }

  /// Short tick, e.g. mode change or "something detected".
  Future<void> tick() => _vibrate(duration: 30);

  /// Action accepted / started.
  Future<void> confirm() => _vibrate(pattern: [0, 40, 60, 40]);

  /// Something failed or was not found.
  Future<void> error() => _vibrate(pattern: [0, 200]);

  /// Obstacle warning; [urgency] 0..1 controls strength and repetition.
  Future<void> obstacle(double urgency) {
    final u = urgency.clamp(0.0, 1.0);
    final strength = (80 + 175 * u).round();
    if (u > 0.75) {
      return _vibrate(pattern: [0, 120, 60, 120, 60, 120], intensities: [0, strength, 0, strength, 0, strength]);
    }
    return _vibrate(pattern: [0, (60 + 120 * u).round()], intensities: [0, strength]);
  }

  /// Plays a sine tone. Used as a "Geiger counter" while searching.
  Future<void> beep({int frequency = 880, int durationMs = 80, double volume = 0.6}) async {
    try {
      await _device.invokeMethod('beep', {'freq': frequency, 'ms': durationMs, 'vol': volume});
    } catch (_) {}
  }

  /// Earcon when the microphone opens.
  Future<void> listeningCue() => beep(frequency: 1200, durationMs: 90, volume: 0.5);

  Future<void> keepScreenOn(bool on) async {
    try {
      await _device.invokeMethod('keepScreenOn', {'on': on});
    } catch (_) {}
  }
}
