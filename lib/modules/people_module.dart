import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/speech/speaker.dart';
import '../core/storage/store.dart';
import '../core/vision/announcer.dart';
import '../core/vision/detection.dart';
import '../core/vision/embedding.dart';
import '../core/vision/frame.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

/// A face found in a frame and, if known, who it is.
class SeenFace {
  final NormRect box;
  final String? name;
  final double score;
  const SeenFace(this.box, this.name, this.score);
}

/// Recognizes people the user has saved, entirely on the phone.
class PeopleModule extends AssistModule {
  @override
  String get id => 'people';
  @override
  String get title => 'People';
  @override
  IconData get icon => Icons.face;
  @override
  Color get color => const Color(0xFF5C3A0F);
  @override
  String get hint =>
      'I will tell you when someone you saved is in front of the camera. Tap to hear who is here. Double tap to save a new person.';
  @override
  String get help =>
      'People mode recognizes faces you have saved. To save someone, ask their permission, double tap, say their name, and point the camera at their face from about one meter while they look at the phone. '
      'Afterwards, I will announce them when they appear, for example "Sara ahead". Tap to hear everyone in view. Say "list people" to hear who is saved, or "forget" followed by a name to delete someone. Face data never leaves the phone.';
  @override
  String get tapLabel => 'Who is here';
  @override
  String get doubleTapLabel => 'Save a new person';

  // MobileFaceNet cosine similarity on roll-aligned crops. Same person is
  // typically above 0.6; the margin guards against look-alikes. Tune with
  // real users if needed.
  static const double matchThreshold = 0.62;

  FaceDetector? _detector;
  List<GalleryEntry> _gallery = [];
  List<SeenFace> _seen = const [];
  final _announcer = Announcer<SeenFace>(cooldown: const Duration(seconds: 30));
  final Map<String, DateTime> _lastLogged = {};
  bool _enrolling = false;

  FaceDetector get detector => _detector ??= FaceDetector(
        options:
            FaceDetectorOptions(performanceMode: FaceDetectorMode.fast, minFaceSize: 0.12, enableClassification: false),
      );

  @override
  Future<void> onEnter() async {
    _gallery = await store.gallery(GalleryKind.person);
    _announcer.reset();
    status = _gallery.isEmpty ? 'No saved people yet. Double tap to save someone.' : 'Looking for faces';
  }

  @override
  Future<void> onExit() async {
    await _detector?.close();
    _detector = null;
  }

  Future<List<SeenFace>> recognize(NV21Frame frame) async {
    final faces = await detector.processImage(CameraService.instance.toInputImage(frame));
    if (faces.isEmpty) return const [];
    final uw = frame.uprightWidth, uh = frame.uprightHeight;
    final used = faces.take(4).toList();
    final boxes = used
        .map((f) => NormRect(
                f.boundingBox.left / uw, f.boundingBox.top / uh, f.boundingBox.right / uw, f.boundingBox.bottom / uh)
            .clamp())
        .toList();
    if (_gallery.isEmpty) return boxes.map((b) => SeenFace(b, null, 0)).toList();
    final crops = boxes.map((b) => b.squareIn(uw, uh)).toList();
    final r = await VisionWorker.instance
        .run(frame, VisionRequest(faceRegions: crops, faceRolls: used.map((f) => f.headEulerAngleZ ?? 0).toList()));
    final res = <SeenFace>[];
    for (int i = 0; i < boxes.length; i++) {
      // Too small to tell people apart reliably.
      final tooSmall = boxes[i].width * uw < 60;
      final m =
          tooSmall ? null : bestGalleryMatch(r.faceEmbeddings[i], _gallery, threshold: matchThreshold, minMargin: 0.05);
      res.add(SeenFace(boxes[i], m?.entry.name, m?.score ?? 0));
    }
    return res;
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    if (_enrolling) return;
    final seen = await recognize(frame);
    _seen = seen;
    if (!active || _enrolling) return;
    if (seen.isEmpty) {
      status = 'No faces in view';
      return;
    }
    status = describeFaces(seen);
    final items = <String, (SeenFace, String)>{};
    for (final f in seen) {
      final key = f.name ?? 'unknown-${items.length}';
      items[key] = (f, directionWord(f.box.centerX));
    }
    final news = _announcer.update(items, DateTime.now());
    final known = news.where((f) => f.name != null).toList();
    if (known.isNotEmpty) {
      cues.tick();
      await say(joinSpoken(known.map((f) => '${f.name} ${directionPhrase(f.box.centerX)}').toList()),
          mode: SpeakMode.ifIdle);
      for (final f in known) {
        final last = _lastLogged[f.name!];
        if (last == null || DateTime.now().difference(last).inMinutes > 30) {
          _lastLogged[f.name!] = DateTime.now();
          await log('person', 'Saw ${f.name}', subject: f.name);
        }
      }
    } else if (news.isNotEmpty && _gallery.isEmpty) {
      await say('A person ${directionPhrase(news.first.box.centerX)}.', mode: SpeakMode.ifIdle);
    }
  }

  String describeFaces(List<SeenFace> seen) {
    final parts = seen.map((f) => '${f.name ?? 'someone I do not know'} ${directionPhrase(f.box.centerX)}').toList();
    return joinSpoken(parts);
  }

  @override
  Future<void> onTap() async {
    final frame = await CameraService.instance.nextFrame();
    if (frame == null) return say('The camera is not ready.');
    final seen = await recognize(frame);
    if (seen.isEmpty) return say('I do not see any faces. Point the camera at head height.');
    final n = seen.length;
    await say('${n == 1 ? 'One person' : '$n people'}: ${describeFaces(seen)}.');
  }

  @override
  Future<void> onDoubleTap() => enroll(null);

  Future<void> enroll(String? name) async {
    if (_enrolling) return;
    _enrolling = true;
    try {
      name ??= await host.ask('What is this person\'s name?');
      if (name == null || name.trim().isEmpty) {
        await say('I did not catch a name. Nothing was saved.');
        return;
      }
      name = _titleCase(name.trim());
      await say('Point the camera at $name\'s face from about one meter. Hold still.');
      final samples = <Float32List>[];
      int attempts = 0;
      while (samples.length < 5 && attempts < 25) {
        attempts++;
        await Future.delayed(const Duration(milliseconds: 350));
        final frame = await CameraService.instance.nextFrame();
        if (frame == null) continue;
        final faces = await detector.processImage(CameraService.instance.toInputImage(frame));
        if (faces.isEmpty) {
          if (attempts % 6 == 0) await say('I do not see a face yet.');
          continue;
        }
        faces.sort((a, b) =>
            (b.boundingBox.width * b.boundingBox.height).compareTo(a.boundingBox.width * a.boundingBox.height));
        final f = faces.first;
        if ((f.headEulerAngleY ?? 0).abs() > 30) continue; // wants a fairly frontal view
        final uw = frame.uprightWidth, uh = frame.uprightHeight;
        final box = NormRect(
                f.boundingBox.left / uw, f.boundingBox.top / uh, f.boundingBox.right / uw, f.boundingBox.bottom / uh)
            .clamp()
            .squareIn(uw, uh);
        if (box.width * uw < 80) {
          if (attempts % 6 == 0) await say('Move a little closer to the face.');
          continue;
        }
        final r = await VisionWorker.instance
            .run(frame, VisionRequest(faceRegions: [box], faceRolls: [f.headEulerAngleZ ?? 0]));
        samples.add(r.faceEmbeddings.first);
        cues.tick();
      }
      if (samples.length < 3) {
        await say('I could not get a clear view of the face. Please try again in better light.');
        return;
      }
      final existing = _gallery.where((g) => g.name.toLowerCase() == name!.toLowerCase()).toList();
      if (existing.isNotEmpty) {
        await store.addSamples(existing.first.id, samples);
        await say('Updated $name with ${samples.length} more pictures.');
      } else {
        await store.addGalleryEntry(GalleryKind.person, name, samples);
        await say('Saved $name.');
      }
      cues.confirm();
      await log('person', 'Saved person $name', subject: name);
      _gallery = await store.gallery(GalleryKind.person);
    } finally {
      _enrolling = false;
    }
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.whoIsHere:
        await onTap();
        return true;
      case VoiceIntent.savePerson:
        await enroll(c.arg);
        return true;
      case VoiceIntent.listSaved:
        final g = await store.gallery(GalleryKind.person);
        await say(g.isEmpty ? 'No people saved yet.' : 'Saved people: ${joinSpoken(g.map((e) => e.name).toList())}.');
        return true;
      default:
        final raw = normalizeUtterance(c.raw);
        if (raw.startsWith('forget ') || raw.startsWith('delete ')) {
          final who = raw.split(' ').skip(1).join(' ');
          final match = matchName(who, _gallery.map((g) => g.name));
          if (match == null) {
            await say('I do not have anyone called $who.');
          } else if (await host.confirm('Delete $match?')) {
            await store.deleteGalleryEntry(_gallery.firstWhere((g) => g.name == match).id);
            _gallery = await store.gallery(GalleryKind.person);
            await say('Deleted $match.');
          }
          return true;
        }
        return false;
    }
  }

  List<SeenFace> get lastSeen => _seen;
}

String _titleCase(String s) =>
    s.split(' ').where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
