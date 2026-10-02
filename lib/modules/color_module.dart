import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/storage/store.dart';
import '../core/vision/color_names.dart';
import '../core/vision/embedding.dart';
import '../core/vision/frame.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// Color identification, light level, and clothing help (garment colors,
/// "does this match", and recognizing clothes you have saved).
class ColorModule extends AssistModule {
  @override
  String get id => 'color';
  @override
  String get title => 'Color & clothing';
  @override
  IconData get icon => Icons.palette;
  @override
  Color get color => const Color(0xFF4A1F5C);
  @override
  String get hint =>
      'Tap to hear the color at the center of the camera. Double tap to describe a piece of clothing. Then show another item and say "does this match".';
  @override
  String get help =>
      'Color and clothing mode. Tap: the color of whatever is in the middle of the camera. Double tap: describe a garment held about half a meter away, including its main colors and whether it is plain or mixed. '
      'After describing one item, show a second one and say "does this match" to get outfit advice. Say "save this as my blue shirt" to remember a piece of clothing; later, double tap will recognize it. '
      'Say "light" to hear how bright the room is. Colors depend on lighting; daylight or a bright room works best.';
  @override
  String get tapLabel => 'Color at center';
  @override
  String get doubleTapLabel => 'Describe clothing';

  ColorShare? _lastGarmentMain;
  String? _lastGarmentDesc;
  DateTime _lastLive = DateTime.fromMillisecondsSinceEpoch(0);
  String? _liveName;

  @override
  bool get wantsFrames => true;

  @override
  Future<void> onEnter() async {
    status = 'Point at something';
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    // Lightweight live readout of the center color for the screen only.
    final now = DateTime.now();
    if (now.difference(_lastLive).inMilliseconds < 400) return;
    _lastLive = now;
    final shares = dominantColors(
        sampleRegion(frame, NormRect.center(0.12, aspect: frame.uprightWidth / frame.uprightHeight), 8),
        k: 2);
    if (shares.isNotEmpty && shares.first.color.name != _liveName) {
      _liveName = shares.first.color.name;
      status = 'Center: $_liveName';
    }
  }

  Future<NV21Frame?> _frame() async {
    final f = await CameraService.instance.nextFrame();
    if (f == null) await say('The camera is not ready.');
    return f;
  }

  @override
  Future<void> onTap() async {
    final f = await _frame();
    if (f == null) return;
    final aspect = f.uprightWidth / f.uprightHeight;
    final shares = dominantColors(sampleRegion(f, NormRect.center(0.15, aspect: aspect), 12), k: 3);
    if (shares.isEmpty) return say('I could not read the color.');
    final main = shares.first;
    final luma = meanLuma(f);
    var msg = main.color.name;
    if (shares.length > 1 && shares[1].fraction > 0.3) msg += ' and ${shares[1].color.name}';
    if (luma < 40) msg += '. It is quite dark, so the color may be off';
    status = msg;
    await say('$msg.');
  }

  @override
  Future<void> onDoubleTap() => describeGarment();

  Future<void> describeGarment() async {
    final f = await _frame();
    if (f == null) return;
    final aspect = f.uprightWidth / f.uprightHeight;
    final region = NormRect.center(0.55, aspect: aspect);
    final shares = dominantColors(sampleRegion(f, region, 24), k: 4);
    if (shares.isEmpty) return say('I could not read the colors.');
    var desc = describeColorMix(shares);
    // Is it a saved piece of clothing?
    final clothes = await store.gallery(GalleryKind.clothing);
    if (clothes.isNotEmpty) {
      final r = await VisionWorker.instance.run(f, VisionRequest(embedRegions: [region]));
      final m = bestGalleryMatch(r.embeddings.first, clothes, threshold: 0.72, minMargin: 0.03);
      if (m != null) desc = 'This looks like your ${m.entry.name}. $desc';
    }
    _lastGarmentMain = shares.first;
    _lastGarmentDesc = desc;
    status = desc;
    await say('$desc. Show another item and say "does this match" to compare.');
  }

  Future<void> matchWithPrevious() async {
    final prev = _lastGarmentMain;
    if (prev == null) {
      return say('First double tap to describe one item, then show the second item and ask again.');
    }
    final f = await _frame();
    if (f == null) return;
    final aspect = f.uprightWidth / f.uprightHeight;
    final shares = dominantColors(sampleRegion(f, NormRect.center(0.55, aspect: aspect), 24), k: 4);
    if (shares.isEmpty) return say('I could not read the colors.');
    final verdict = colorsMatch(prev.color, shares.first.color);
    final msg =
        '${verdict.goesWell ? 'Yes, these go well together' : 'These may not go well together'}: ${verdict.reason}. '
        'This item is ${describeColorMix(shares)}.';
    status = msg;
    await log('clothing', msg);
    _lastGarmentMain = shares.first;
    await say(msg);
  }

  Future<void> saveGarment(String? name) async {
    name ??= await host.ask('What should I call this piece of clothing? For example, blue shirt.');
    if (name == null || name.trim().isEmpty) return say('Not saved.');
    await say('Hold the item in front of the camera. I will take a few pictures. Move it slightly between them.');
    final samples = <(Float32List, String)>[];
    for (int i = 0; i < 4; i++) {
      await Future.delayed(const Duration(milliseconds: 700));
      final f = await CameraService.instance.nextFrame();
      if (f == null) continue;
      final region = NormRect.center(0.55, aspect: f.uprightWidth / f.uprightHeight);
      final r = await VisionWorker.instance.run(f, VisionRequest(embedRegions: [region]));
      samples.add((r.embeddings.first, dominantColors(sampleRegion(f, region, 16)).first.color.name));
      cues.tick();
    }
    if (samples.isEmpty) return say('Could not capture the item.');
    await store.addGalleryEntry(GalleryKind.clothing, name.trim(), samples.map((s) => s.$1).toList(),
        extra: {'color': samples.first.$2});
    await log('clothing', 'Saved clothing item ${name.trim()}', subject: name.trim());
    cues.confirm();
    await say('Saved ${name.trim()}.');
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.color:
        await onTap();
        return true;
      case VoiceIntent.clothing:
        await describeGarment();
        return true;
      case VoiceIntent.matchClothes:
        await matchWithPrevious();
        return true;
      case VoiceIntent.lightLevel:
        final f = await _frame();
        if (f != null) await say('The light is ${lightLevel(meanLuma(f))}.');
        return true;
      case VoiceIntent.saveObject:
        await saveGarment(c.arg);
        return true;
      default:
        return false;
    }
  }

  String? get lastGarmentDescription => _lastGarmentDesc;
}
