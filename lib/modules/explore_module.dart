import 'package:flutter/material.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/settings.dart';
import '../core/speech/speaker.dart';
import '../core/vision/announcer.dart';
import '../core/vision/color_names.dart';
import '../core/vision/detection.dart';
import '../core/vision/frame.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// Object recognition + scene description.
///
/// Live: announces objects as they come into view with their direction.
/// Tap: a full description of the scene (place type, objects with rough
/// distances, lighting, whether there is text to read).
class ExploreModule extends AssistModule {
  @override
  String get id => 'explore';
  @override
  String get title => 'Explore';
  @override
  IconData get icon => Icons.visibility;
  @override
  Color get color => const Color(0xFF0F3D5C);
  @override
  String get hint =>
      'Point the camera around. I will name objects as they appear. Tap to describe the whole scene. Double tap to pause live announcements.';
  @override
  String get help =>
      'Explore mode recognizes about 80 kinds of everyday objects, such as people, chairs, cups, bottles, laptops, cars and animals, and tells you where they are: on your left, ahead, or on your right. Walls and doors are not recognized as objects. '
      'Tap once for a detailed scene description, including a guess of the kind of place, rough distances, the lighting, and whether there is text to read. '
      'Double tap to turn live announcements on or off.';
  @override
  String get tapLabel => 'Describe scene';
  @override
  String get doubleTapLabel => live ? 'Pause live announcements' : 'Resume live announcements';

  bool live = true;
  final _announcer = Announcer<Detection>();
  List<Detection> lastDetections = const [];
  ImageLabeler? _labeler;
  TextRecognizer? _textRecognizer;
  bool _describing = false;

  @override
  Future<void> onEnter() async {
    _announcer.reset();
    status = live ? 'Looking…' : 'Live announcements paused';
  }

  @override
  Future<void> onExit() async {
    await _labeler?.close();
    _labeler = null;
    await _textRecognizer?.close();
    _textRecognizer = null;
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    if (_describing) return;
    final r = await VisionWorker.instance.run(frame, const VisionRequest(objects: true, objectConf: 0.45));
    lastDetections = r.objects;
    if (!active || _describing) return;
    status = r.objects.isEmpty ? 'Nothing recognized' : describeDetections(r.objects);
    if (!live) return;
    final byLabel = <String, (Detection, String)>{};
    for (final d in r.objects) {
      final prev = byLabel[d.label];
      if (prev == null || d.box.area > prev.$1.box.area) {
        byLabel[d.label] = (d, directionWord(d.box.centerX));
      }
    }
    final news = _announcer.update(byLabel, DateTime.now());
    if (news.isNotEmpty) {
      final phrase = news.take(3).map((d) => '${d.label} ${_dir(d.box.centerX)}').join(', ');
      cues.tick();
      await say(phrase, mode: SpeakMode.ifIdle);
    }
  }

  String _dir(double cx) => Settings.instance.useClockDirections ? 'at ${clockDirection(cx)}' : directionPhrase(cx);

  @override
  Future<void> onTap() => describeScene();

  @override
  Future<void> onDoubleTap() async {
    live = !live;
    _announcer.reset();
    status = live ? 'Looking…' : 'Live announcements paused';
    await say(live ? 'Live announcements on.' : 'Live announcements paused. Tap to describe the scene.');
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.describeScene:
        await describeScene();
        return true;
      case VoiceIntent.whatsAhead:
        await whatsAhead();
        return true;
      default:
        return false;
    }
  }

  Future<void> whatsAhead() async {
    final frame = await CameraService.instance.nextFrame();
    if (frame == null) return say('The camera is not ready.');
    final r = await VisionWorker.instance.run(frame, const VisionRequest(objects: true, objectConf: 0.4));
    if (r.objects.isEmpty) {
      return say('I do not recognize any objects. Try tapping for a full scene description.');
    }
    await say(_withDistances(r.objects));
  }

  String _withDistances(List<Detection> dets) {
    final sorted = [...dets]..sort((a, b) => b.box.area.compareTo(a.box.area));
    final parts = <String>[];
    final seen = <String>{};
    for (final d in sorted) {
      if (!seen.add(d.label)) continue;
      final dist = estimateDistanceMeters(d);
      final count = dets.where((x) => x.label == d.label).length;
      final noun = count == 1 ? withArticle(d.label) : '$count ${pluralize(d.label)}';
      parts.add('$noun ${_dir(d.box.centerX)}${dist != null ? ', ${distancePhrase(dist)}' : ''}');
      if (parts.length >= 6) break;
    }
    return '${joinSpoken(parts)}.';
  }

  Future<void> describeScene() async {
    if (_describing) return;
    _describing = true;
    status = 'Describing…';
    cues.confirm();
    try {
      final cam = CameraService.instance;
      final frame = await cam.nextFrame();
      if (frame == null) {
        await say('The camera is not ready.');
        return;
      }
      final input = cam.toInputImage(frame);
      _labeler ??= ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.6));
      _textRecognizer ??= TextRecognizer(script: TextRecognitionScript.latin);
      final results = await Future.wait([
        VisionWorker.instance.run(frame, const VisionRequest(objects: true, objectConf: 0.35)),
        _labeler!.processImage(input),
        _textRecognizer!.processImage(input),
      ]);
      final objects = (results[0] as VisionResult).objects;
      final labels = results[1] as List<ImageLabel>;
      final text = results[2] as RecognizedText;
      final luma = meanLuma(frame);
      final description = composeSceneDescription(
        objects: objects,
        labels: labels.map((l) => (l.label, l.confidence)).toList(),
        textWordCount: text.text.split(RegExp(r'\s+')).where((w) => w.length > 1).length,
        luma: luma,
        dominant: dominantColors(sampleRegion(frame, NormRect.full, 16), k: 3),
        clock: Settings.instance.useClockDirections,
      );
      status = description;
      await log('scene', description);
      await say(description);
    } catch (e) {
      await say('Sorry, I could not describe the scene.');
    } finally {
      _describing = false;
    }
  }
}

/// Builds a natural spoken scene description from offline model outputs.
String composeSceneDescription({
  required List<Detection> objects,
  required List<(String, double)> labels,
  required int textWordCount,
  required double luma,
  required List<ColorShare> dominant,
  bool clock = false,
}) {
  final sentences = <String>[];
  final objectLabels = objects.map((o) => o.label.toLowerCase()).toSet();
  // Labels that describe the place rather than repeat detected objects.
  const placeWords = {
    'room',
    'kitchen',
    'bathroom',
    'bedroom',
    'office',
    'classroom',
    'restaurant',
    'shop',
    'store',
    'street',
    'road',
    'building',
    'sky',
    'garden',
    'park',
    'beach',
    'stairs',
    'hallway',
    'mosque',
    'market',
    'car',
    'bus',
    'train',
    'desk',
    'couch',
    'bed',
    'tree',
    'grass',
    'water',
    'snow',
    'night',
    'city',
    'house',
    'window',
    'door',
    'curtain',
    'wall',
    'ceiling',
    'floor',
    'shelf',
    'table',
  };
  final sceneLabels =
      labels.where((l) => !objectLabels.contains(l.$1.toLowerCase())).map((l) => l.$1.toLowerCase()).toList();
  final places = sceneLabels.where(placeWords.contains).take(3).toList();
  final others = sceneLabels.where((l) => !placeWords.contains(l)).take(3).toList();
  if (places.isNotEmpty) {
    sentences.add('This looks like ${joinSpoken(places.map((p) => withArticle(p)).toList())}.');
  } else if (others.isNotEmpty) {
    sentences.add('I think I see ${joinSpoken(others)}.');
  }
  if (objects.isNotEmpty) {
    final sorted = [...objects]..sort((a, b) => b.box.area.compareTo(a.box.area));
    final parts = <String>[];
    final seen = <String>{};
    for (final d in sorted) {
      if (!seen.add(d.label)) continue;
      final n = objects.where((x) => x.label == d.label).length;
      final noun = n == 1 ? withArticle(d.label) : '$n ${pluralize(d.label)}';
      final dir = clock ? 'at ${clockDirection(d.box.centerX)}' : directionPhrase(d.box.centerX);
      final dist = estimateDistanceMeters(d);
      parts.add('$noun $dir${dist != null && parts.length < 3 ? ', ${distancePhrase(dist)}' : ''}');
      if (parts.length >= 6) break;
    }
    sentences.add('There ${objects.length == 1 ? 'is' : 'are'} ${joinSpoken(parts)}.');
  } else if (places.isEmpty && others.isEmpty) {
    sentences.add('I cannot make out anything specific.');
  }
  if (places.isNotEmpty && others.isNotEmpty && objects.length < 3) {
    sentences.add('I also notice ${joinSpoken(others.take(2).toList())}.');
  }
  final main = dominant.isNotEmpty ? dominant.first.color.name : null;
  sentences.add('The lighting is ${lightLevel(luma)}${main != null ? ', and the main color is $main' : ''}.');
  if (textWordCount >= 3) {
    sentences.add(textWordCount > 25
        ? 'There is a lot of text here; use the text reader to read it.'
        : 'There is some text visible.');
  }
  return sentences.join(' ');
}
