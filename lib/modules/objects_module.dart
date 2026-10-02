import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/speech/speaker.dart';
import '../core/storage/store.dart';
import '../core/vision/detection.dart';
import '../core/vision/embedding.dart';
import '../core/vision/frame.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// Regions scanned for saved objects: the center, the left/right thirds,
/// and boxes of any generic objects the detector found.
List<NormRect> searchRegions(List<Detection> dets, int uw, int uh) {
  final aspect = uw / uh;
  final regions = <NormRect>[
    NormRect.center(0.45, aspect: aspect),
    const NormRect(0.0, 0.25, 0.4, 0.75).squareIn(uw, uh),
    const NormRect(0.6, 0.25, 1.0, 0.75).squareIn(uw, uh),
  ];
  for (final d in dets.take(3)) {
    if (d.label == 'person') continue;
    regions.add(d.box.inflate(0.15).squareIn(uw, uh));
  }
  return regions;
}

/// Saved object recognition and "find my object" with an audio
/// Geiger-counter: faster, higher beeps mean you are pointing closer to it.
class ObjectsModule extends AssistModule {
  @override
  String get id => 'objects';
  @override
  String get title => 'My objects';
  @override
  IconData get icon => Icons.key;
  @override
  Color get color => const Color(0xFF0F5C55);
  @override
  String get hint =>
      'Tap and say which object to find, then slowly sweep the phone around; beeps get faster as you get closer. Double tap to save a new object.';
  @override
  String get help =>
      'My objects lets you teach the app your own things, like your keys, wallet, glasses or medicine box. Double tap, say the name, and hold the object in front of the camera while turning it slightly. '
      'To find something, tap or say "find my keys", then sweep the phone slowly. Beeps speed up when the object is in view and I will say where it is. '
      'Whenever a saved object is seen I note the time and place, so you can ask "where did I leave my keys". Say "list objects" to hear what is saved.';
  @override
  String get tapLabel => target == null ? 'Choose object to find' : 'Stop finding ${target!.name}';
  @override
  String get doubleTapLabel => 'Save a new object';

  static const double threshold = 0.68;

  List<GalleryEntry> _gallery = [];
  GalleryEntry? target;
  bool _enrolling = false;
  DateTime _lastBeep = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, DateTime> _lastLogged = {};

  @override
  Future<void> onEnter() async {
    _gallery = await store.gallery(GalleryKind.object);
    status = target != null
        ? 'Finding ${target!.name}'
        : _gallery.isEmpty
            ? 'No objects saved yet. Double tap to save one.'
            : 'Watching for your ${_gallery.length} saved objects';
  }

  Future<void> refresh() async => _gallery = await store.gallery(GalleryKind.object);

  @override
  Future<void> onFrame(NV21Frame frame) async {
    if (_enrolling || _gallery.isEmpty) return;
    final uw = frame.uprightWidth, uh = frame.uprightHeight;
    final first = await VisionWorker.instance.run(frame, const VisionRequest(objects: true, objectConf: 0.3));
    final regions = searchRegions(first.objects, uw, uh);
    final r = await VisionWorker.instance.run(frame, VisionRequest(embedRegions: regions));
    if (!active || _enrolling) return;

    final candidates = target != null ? [target!] : _gallery;
    double bestScore = 0;
    GalleryMatch? best;
    NormRect? bestRegion;
    for (int i = 0; i < regions.length; i++) {
      final m = bestGalleryMatch(r.embeddings[i], candidates, threshold: 0, minMargin: 0);
      if (m != null && m.score > bestScore) {
        // When scanning for anything, make sure it is not closer to another saved object.
        if (target == null) {
          final all = bestGalleryMatch(r.embeddings[i], _gallery, threshold: 0, minMargin: 0);
          if (all != null && all.entry.id != m.entry.id) continue;
        }
        bestScore = m.score;
        best = m;
        bestRegion = regions[i];
      }
    }
    final now = DateTime.now();
    if (target != null) {
      // Geiger counter: map similarity to beep rate and pitch.
      final closeness = ((bestScore - 0.45) / (threshold - 0.45)).clamp(0.0, 1.2);
      final interval = (900 - 700 * closeness.clamp(0.0, 1.0)).round();
      if (closeness > 0.15 && now.difference(_lastBeep).inMilliseconds > interval) {
        _lastBeep = now;
        cues.beep(frequency: 500 + (closeness * 700).round(), durationMs: 60, volume: 0.7);
      }
      status = bestScore >= threshold
          ? '${target!.name} ${directionPhrase(bestRegion!.centerX)}'
          : 'Searching for ${target!.name}';
    }
    if (best != null && bestScore >= threshold) {
      final name = best.entry.name;
      if (now.difference(_lastSpoken).inSeconds > 4) {
        _lastSpoken = now;
        cues.confirm();
        await say('${_cap(name)} ${directionPhrase(bestRegion!.centerX)}.', mode: SpeakMode.ifIdle);
      }
      if (target == null) status = '${_cap(name)} ${directionPhrase(bestRegion!.centerX)}';
      final last = _lastLogged[name];
      if (last == null || now.difference(last).inMinutes > 10) {
        _lastLogged[name] = now;
        final place = host.currentPlace;
        await log('sighting', 'Saw your $name${place != null ? ' near $place' : ''}', subject: name);
      }
    } else if (target == null) {
      status = 'Watching for your ${_gallery.length} saved objects';
    }
  }

  @override
  Future<void> onTap() async {
    if (target != null) {
      final name = target!.name;
      target = null;
      status = 'Stopped finding $name';
      return say('Stopped finding $name.');
    }
    if (_gallery.isEmpty) return say('You have not saved any objects yet. Double tap to save one.');
    final ans =
        await host.ask('Which object should I find? You have ${joinSpoken(_gallery.map((g) => g.name).toList())}.');
    if (ans == null) return say('I did not hear a name.');
    await startFinding(ans);
  }

  Future<void> startFinding(String spoken) async {
    if (_gallery.isEmpty) await refresh();
    final name = matchName(spoken, _gallery.map((g) => g.name));
    if (name == null) {
      return say(
          'I do not have an object called $spoken saved. ${_gallery.isEmpty ? 'Double tap in My objects to save one.' : 'Saved objects are ${joinSpoken(_gallery.map((g) => g.name).toList())}.'}');
    }
    target = _gallery.firstWhere((g) => g.name == name);
    status = 'Finding $name';
    final last = await store.events(subject: name, kind: 'sighting', limit: 1);
    final lastNote = last.isEmpty
        ? ''
        : ' I last saw it ${_ago(last.first.time)}${last.first.text.contains(' near ') ? ' near ${last.first.text.split(' near ').last}' : ''}.';
    await say('Finding your $name. Sweep the phone slowly.$lastNote');
  }

  @override
  Future<void> onDoubleTap() => enroll(null);

  Future<void> enroll(String? name) async {
    if (_enrolling) return;
    _enrolling = true;
    try {
      name ??= await host.ask('What is the object called? For example, keys.');
      if (name == null || name.trim().isEmpty) {
        await say('Nothing was saved.');
        return;
      }
      name = name.trim().toLowerCase().replaceFirst(RegExp(r'^(my|the) '), '');
      await say(
          'Hold your $name about 30 centimeters in front of the camera. I will take 6 pictures; turn it a little between each beep.');
      final samples = <Float32List>[];
      for (int i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 800));
        final f = await CameraService.instance.nextFrame();
        if (f == null) continue;
        final uw = f.uprightWidth, uh = f.uprightHeight;
        final det = await VisionWorker.instance.run(f, const VisionRequest(objects: true, objectConf: 0.35));
        final regions = <NormRect>[NormRect.center(0.45, aspect: uw / uh)];
        // If the detector sees a non-person object near the center, use its box too.
        final central = det.objects.where(
            (d) => d.label != 'person' && (d.box.centerX - 0.5).abs() < 0.25 && (d.box.centerY - 0.5).abs() < 0.25);
        if (central.isNotEmpty) regions.add(central.first.box.inflate(0.15).squareIn(uw, uh));
        final r = await VisionWorker.instance.run(f, VisionRequest(embedRegions: regions));
        samples.addAll(r.embeddings);
        cues.beep(frequency: 900, durationMs: 50);
      }
      if (samples.isEmpty) {
        await say('I could not capture the object.');
        return;
      }
      await refresh();
      final existing = _gallery.where((g) => g.name == name).toList();
      if (existing.isNotEmpty) {
        await store.addSamples(existing.first.id, samples);
      } else {
        await store.addGalleryEntry(GalleryKind.object, name, samples);
      }
      await refresh();
      await log('object', 'Saved object $name', subject: name);
      cues.confirm();
      await say(
          'Saved your $name. For better recognition, save it again later in a different spot; I will add the new pictures.');
    } finally {
      _enrolling = false;
    }
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.findObject:
        if (c.arg != null) {
          await startFinding(c.arg!);
        } else {
          await onTap();
        }
        return true;
      case VoiceIntent.saveObject:
        await enroll(c.arg);
        return true;
      case VoiceIntent.listSaved:
        await refresh();
        await say(_gallery.isEmpty
            ? 'No objects saved yet.'
            : 'Saved objects: ${joinSpoken(_gallery.map((e) => e.name).toList())}.');
        return true;
      case VoiceIntent.stop:
      case VoiceIntent.cancel:
        if (target != null) {
          await onTap();
          return true;
        }
        return false;
      default:
        final raw = normalizeUtterance(c.raw);
        if (raw.startsWith('forget ') || raw.startsWith('delete ')) {
          await refresh();
          final what = raw.split(' ').skip(1).join(' ');
          final match = matchName(what, _gallery.map((g) => g.name));
          if (match == null) {
            await say('No saved object called $what.');
          } else if (await host.confirm('Delete $match?')) {
            await store.deleteGalleryEntry(_gallery.firstWhere((g) => g.name == match).id);
            await refresh();
            await say('Deleted $match.');
          }
          return true;
        }
        return false;
    }
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// "5 minutes ago", "today at 3:15 PM", "yesterday", "on 12/3".
String _ago(DateTime t) => timeAgo(t, DateTime.now());

String timeAgo(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'} ago';
  final hm =
      '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final today = DateTime(now.year, now.month, now.day);
  if (!t.isBefore(today)) return 'today at $hm';
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'yesterday at $hm';
  return 'on ${t.day}/${t.month} at $hm';
}
