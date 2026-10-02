import 'package:flutter/material.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/speech/speaker.dart';
import '../core/vision/detection.dart';
import '../core/vision/frame.dart';
import '../core/vision/labels.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// Spoken amount, e.g. 1500 -> "1,500 rupees".
String rupees(int amount) {
  final s = amount.toString();
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${b.toString()} ${amount == 1 ? 'rupee' : 'rupees'}';
}

/// Summarizes all notes in view: "2 notes: 500 and 100 rupees, total 600 rupees".
String describeNotes(List<Detection> notes) {
  if (notes.isEmpty) return 'No currency note found.';
  final values = notes.map((n) => pkrValue(n.label)).toList()..sort((a, b) => b.compareTo(a));
  final total = values.fold(0, (a, b) => a + b);
  if (values.length == 1) return rupees(values.first);
  return '${values.length} notes: ${joinSpoken(values.map((v) => '$v').toList())}. Total ${rupees(total)}.';
}

/// Pakistani rupee note recognition using the custom-trained YOLO11n model.
class CurrencyModule extends AssistModule {
  @override
  String get id => 'currency';
  @override
  String get title => 'Currency';
  @override
  IconData get icon => Icons.payments;
  @override
  Color get color => const Color(0xFF0F4D2A);
  @override
  String get hint =>
      'Hold a note flat about 20 centimeters from the camera. I will say its value. Tap to count all notes in view. Double tap to add the current note to a running total.';
  @override
  String get help =>
      'Currency mode recognizes Pakistani rupee notes of 10, 20, 50, 100, 500, 1000 and 5000. Hold one note at a time in good light. '
      'Tap to count every note in view and hear the total. To count a bundle, double tap after each note is recognized to add it to a running total; say "what is the total" to hear it, or "reset total" to start again. '
      'Coins are not recognized.';
  @override
  String get tapLabel => 'Count notes in view';
  @override
  String get doubleTapLabel => 'Add note to running total';

  final List<List<String>> _history = []; // labels per recent frame
  String? _lastAnnounced;
  DateTime _lastAnnouncedAt = DateTime.fromMillisecondsSinceEpoch(0);
  List<Detection> _current = const [];
  int runningTotal = 0;
  int runningCount = 0;
  String? _lastAddedLabel;
  DateTime _lastAddedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> onEnter() async {
    _history.clear();
    status = runningCount > 0 ? 'Running total: ${rupees(runningTotal)}' : 'Show a note';
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    final r = await VisionWorker.instance.run(frame, const VisionRequest(currency: true, currencyConf: 0.55));
    _current = r.currency;
    if (!active) return;
    _history.add(r.currency.map((d) => d.label).toList());
    if (_history.length > 3) _history.removeAt(0);
    if (r.currency.isEmpty) {
      status = runningCount > 0 ? 'Running total: ${rupees(runningTotal)}' : 'No note in view';
      return;
    }
    // The most confident note must appear in at least 2 of the last 3 frames.
    final best = r.currency.first;
    final hits = _history.where((h) => h.contains(best.label)).length;
    if (hits < 2) return;
    final value = pkrValue(best.label);
    status = r.currency.length > 1 ? describeNotes(r.currency) : rupees(value);
    final now = DateTime.now();
    if (best.label != _lastAnnounced || now.difference(_lastAnnouncedAt).inSeconds > 5) {
      _lastAnnounced = best.label;
      _lastAnnouncedAt = now;
      cues.tick();
      await say(r.currency.length > 1 ? describeNotes(r.currency) : rupees(value), mode: SpeakMode.ifIdle);
      await log('currency', 'Identified ${rupees(value)}');
    }
  }

  @override
  Future<void> onTap() async {
    final frame = await CameraService.instance.nextFrame();
    if (frame == null) return say('The camera is not ready.');
    final r = await VisionWorker.instance.run(frame, const VisionRequest(currency: true, currencyConf: 0.45));
    final msg = describeNotes(r.currency);
    status = msg;
    await say(msg);
  }

  @override
  Future<void> onDoubleTap() async {
    if (_current.isEmpty) {
      return say('No note in view to add. Running total is ${rupees(runningTotal)}.');
    }
    final best = _current.first;
    final now = DateTime.now();
    if (best.label == _lastAddedLabel && now.difference(_lastAddedAt).inSeconds < 2) {
      return say('Already added. Show the next note.');
    }
    _lastAddedLabel = best.label;
    _lastAddedAt = now;
    final v = pkrValue(best.label);
    runningTotal += v;
    runningCount++;
    status = 'Running total: ${rupees(runningTotal)}';
    cues.confirm();
    await say('Added $v. Total ${rupees(runningTotal)}, $runningCount ${runningCount == 1 ? 'note' : 'notes'}.');
  }

  @override
  Future<bool> handle(Command c) async {
    final raw = c.raw.toLowerCase();
    if (raw.contains('reset') || raw.contains('clear total') || raw.contains('start over')) {
      runningTotal = 0;
      runningCount = 0;
      status = 'Show a note';
      await say('Running total cleared.');
      return true;
    }
    if (raw.contains('total')) {
      await say('Running total is ${rupees(runningTotal)} from $runningCount notes.');
      return true;
    }
    if (c.intent == VoiceIntent.currency) {
      await onTap();
      return true;
    }
    return false;
  }
}
