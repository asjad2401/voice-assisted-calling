import 'package:flutter/material.dart';

import '../core/commands.dart';
import '../core/speech/speaker.dart';
import '../core/vision/detection.dart';
import '../core/vision/frame.dart';
import '../core/vision/labels.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// A ranked hazard in the current frame.
class Hazard {
  final Detection detection;
  final double? meters;
  final bool inPath;
  final double urgency; // 0..1
  const Hazard(this.detection, this.meters, this.inPath, this.urgency);
}

/// Scores detections as walking hazards. Pure so it can be tested.
List<Hazard> rankHazards(List<Detection> dets) {
  final res = <Hazard>[];
  for (final d in dets) {
    if (!obstacleLabels.contains(d.label)) continue;
    final m = estimateDistanceMeters(d);
    final overlapsPath = d.box.right > 0.3 && d.box.left < 0.7;
    final moving = movingHazards.contains(d.label);
    // Apparent size is a fallback for proximity when the class size is unknown.
    final closeness = m != null ? (1 - (m / (moving ? 8 : 4))).clamp(0.0, 1.0) : (d.box.area * 2).clamp(0.0, 1.0);
    double urgency = closeness * (overlapsPath ? 1.0 : 0.55);
    if (moving) urgency = (urgency * 1.25).clamp(0.0, 1.0);
    if (urgency < 0.15) continue;
    res.add(Hazard(d, m, overlapsPath, urgency));
  }
  res.sort((a, b) => b.urgency.compareTo(a.urgency));
  return res;
}

/// Continuous obstacle alerts while walking: vibration strength follows
/// how close the nearest obstacle in your path is, and speech names it.
class ObstacleModule extends AssistModule {
  @override
  String get id => 'obstacles';
  @override
  String get title => 'Obstacle alerts';
  @override
  IconData get icon => Icons.directions_walk;
  @override
  Color get color => const Color(0xFF5C1A0F);
  @override
  String get hint =>
      'Hold the phone in front of your chest, camera facing forward. I will vibrate and speak when something is in your way. Tap to check the path. Double tap to pause.';
  @override
  String get help =>
      'Obstacle alerts watch the path ahead. Stronger vibration means closer. Vehicles, people, animals, furniture and other common obstacles are named with their direction and rough distance. '
      'This is an aid only: it does not see walls, steps, holes or glass, so keep using your cane or guide. Tap to hear whether the path is clear. Double tap to pause or resume.';
  @override
  String get tapLabel => 'Check the path';
  @override
  String get doubleTapLabel => paused ? 'Resume alerts' : 'Pause alerts';

  bool paused = false;
  List<Hazard> _hazards = const [];
  final Map<String, DateTime> _lastSpoken = {};
  DateTime _lastBuzz = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> onEnter() async {
    cues.keepScreenOn(true);
    status = paused ? 'Paused' : 'Watching the path';
  }

  @override
  Future<void> onExit() async {
    cues.keepScreenOn(false);
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    final r = await VisionWorker.instance.run(frame, const VisionRequest(objects: true, objectConf: 0.35));
    _hazards = rankHazards(r.objects);
    if (!active || paused) return;
    if (_hazards.isEmpty) {
      status = 'Path looks clear';
      return;
    }
    final top = _hazards.first;
    status = _phrase(top);
    final now = DateTime.now();
    if (now.difference(_lastBuzz).inMilliseconds > 700) {
      _lastBuzz = now;
      cues.obstacle(top.urgency);
    }
    final key = '${top.detection.label}-${directionWord(top.detection.box.centerX)}';
    final last = _lastSpoken[key];
    final repeatAfter = top.urgency > 0.75 ? 3 : 6;
    if (top.urgency >= 0.4 && (last == null || now.difference(last).inSeconds >= repeatAfter)) {
      _lastSpoken[key] = now;
      final urgent = top.urgency > 0.8 && top.inPath;
      await say(urgent ? 'Stop. ${_phrase(top)}' : _phrase(top), mode: urgent ? SpeakMode.interrupt : SpeakMode.ifIdle);
    }
  }

  String _phrase(Hazard h) {
    final d = h.detection;
    final dist = h.meters != null ? ', ${distancePhrase(h.meters!)}' : '';
    return '${d.label[0].toUpperCase()}${d.label.substring(1)} ${directionPhrase(d.box.centerX)}$dist';
  }

  @override
  Future<void> onTap() async {
    if (_hazards.isEmpty) {
      return say('No obstacles detected ahead. Remember I cannot see walls, steps or holes.');
    }
    final parts = _hazards.take(3).map(_phrase).toList();
    await say('${joinSpoken(parts)}.');
  }

  @override
  Future<void> onDoubleTap() async {
    paused = !paused;
    status = paused ? 'Paused' : 'Watching the path';
    await say(paused ? 'Obstacle alerts paused.' : 'Obstacle alerts on.');
  }

  @override
  Future<bool> handle(Command c) async {
    if (c.intent == VoiceIntent.obstacles) {
      if (paused) await onDoubleTap();
      await onTap();
      return true;
    }
    return false;
  }
}
