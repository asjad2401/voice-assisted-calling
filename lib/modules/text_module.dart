import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/speech/speaker.dart';
import '../core/vision/frame.dart';
import 'module.dart';

/// Framing advice for a set of text block boxes (normalized, upright).
/// Returns null when the text is well framed.
String? framingAdvice(List<NormRect> blocks) {
  if (blocks.isEmpty) return null;
  double l = 1, t = 1, r = 0, b = 0;
  for (final x in blocks) {
    if (x.left < l) l = x.left;
    if (x.top < t) t = x.top;
    if (x.right > r) r = x.right;
    if (x.bottom > b) b = x.bottom;
  }
  final cutLeft = l < 0.02, cutRight = r > 0.98, cutTop = t < 0.02, cutBottom = b > 0.98;
  if ((cutLeft && cutRight) || (cutTop && cutBottom)) return 'Text is cut off. Move the phone further away.';
  if (cutLeft) return 'Text is cut off on the left. Move the phone a little to the left.';
  if (cutRight) return 'Text is cut off on the right. Move the phone a little to the right.';
  if (cutTop) return 'Text is cut off at the top. Move the phone up a little.';
  if (cutBottom) return 'Text is cut off at the bottom. Move the phone down a little.';
  if ((r - l) * (b - t) < 0.04) return 'The text is small. Move the phone closer.';
  return null;
}

/// Orders recognized blocks into natural reading order (top-to-bottom,
/// then left-to-right for blocks on the same line band).
List<TextBlock> readingOrder(List<TextBlock> blocks) {
  final sorted = [...blocks];
  sorted.sort((a, b) {
    final ay = a.boundingBox.top, by = b.boundingBox.top;
    final band = (a.boundingBox.height + b.boundingBox.height) / 4;
    if ((ay - by).abs() < band) return a.boundingBox.left.compareTo(b.boundingBox.left);
    return ay.compareTo(by);
  });
  return sorted;
}

/// Reads printed text: short labels live, and full pages from a sharp
/// still photo.
class TextModule extends AssistModule {
  @override
  String get id => 'text';
  @override
  String get title => 'Read text';
  @override
  IconData get icon => Icons.chrome_reader_mode;
  @override
  Color get color => const Color(0xFF2E2A0F);
  @override
  String get hint =>
      'Hold the phone about 30 centimeters above the page. I will tell you when text is in view. Tap to read it all. Double tap to read the short text live.';
  @override
  String get help =>
      'Text reader works offline for English and other Latin-alphabet languages. Tap to take a sharp photo and read the whole page or label in reading order; tap again to stop. '
      'While you aim, I give hints like move left or move closer when the text is cut off. Double tap to switch quick live reading on or off, which reads short signs and labels as soon as they appear.';
  @override
  String get tapLabel => _reading ? 'Stop reading' : 'Read page';
  @override
  String get doubleTapLabel => quickRead ? 'Stop quick reading' : 'Quick read short text';

  TextRecognizer? _recognizer;
  bool quickRead = false;
  bool _reading = false;
  bool _ocrBusy = false;
  DateTime _lastHint = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastQuickText = '';
  int _framesWithText = 0;

  TextRecognizer get recognizer => _recognizer ??= TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<void> onEnter() async {
    status = 'Aim at text';
    _framesWithText = 0;
  }

  @override
  Future<void> onExit() async {
    _reading = false;
    await _recognizer?.close();
    _recognizer = null;
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    if (_reading || _ocrBusy) return;
    _ocrBusy = true;
    try {
      final text = await recognizer.processImage(CameraService.instance.toInputImage(frame));
      if (!active || _reading) return;
      final uw = frame.uprightWidth.toDouble(), uh = frame.uprightHeight.toDouble();
      final boxes = text.blocks
          .map((b) => NormRect(
              b.boundingBox.left / uw, b.boundingBox.top / uh, b.boundingBox.right / uw, b.boundingBox.bottom / uh))
          .toList();
      final words = text.text.split(RegExp(r'\s+')).where((w) => w.length > 1).length;
      if (words == 0) {
        _framesWithText = 0;
        status = 'No text in view';
        return;
      }
      _framesWithText++;
      status = '$words words in view';
      if (quickRead) {
        final t = readingOrder(text.blocks).map((b) => b.text).join('. ');
        if (_similarity(t, _lastQuickText) < 0.6 && words <= 40) {
          _lastQuickText = t;
          await say(t, mode: SpeakMode.ifIdle);
        }
        return;
      }
      final now = DateTime.now();
      if (now.difference(_lastHint).inSeconds < 4) return;
      final advice = framingAdvice(boxes);
      if (_framesWithText == 2) {
        _lastHint = now;
        cues.tick();
        await say(advice ?? 'Text in view. Tap to read.', mode: SpeakMode.ifIdle);
      } else if (advice != null && _framesWithText % 6 == 0) {
        _lastHint = now;
        await say(advice, mode: SpeakMode.ifIdle);
      }
    } finally {
      _ocrBusy = false;
    }
  }

  double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final wa = a.toLowerCase().split(RegExp(r'\W+')).toSet();
    final wb = b.toLowerCase().split(RegExp(r'\W+')).toSet();
    return wa.intersection(wb).length / wa.union(wb).length;
  }

  @override
  Future<void> onTap() async {
    if (_reading) {
      _reading = false;
      await speaker.stop();
      await say('Stopped.');
      return;
    }
    await readPage();
  }

  Future<void> readPage() async {
    _reading = true;
    status = 'Reading…';
    cues.confirm();
    await say('Hold still.');
    final path = await CameraService.instance.takePicture(flashIfDark: true);
    if (path == null) {
      _reading = false;
      return say('Could not take a photo.');
    }
    try {
      final text = await recognizer.processImage(InputImage.fromFilePath(path));
      final blocks = readingOrder(text.blocks);
      if (blocks.isEmpty) {
        await say(
            'I could not find any text. Try holding the phone a little further away, and make sure the page is lit.');
        return;
      }
      final paragraphs = blocks.map((b) => b.lines.map((l) => l.text).join(' ')).toList();
      final full = paragraphs.join('\n');
      status = full;
      await log('read', full.length > 300 ? '${full.substring(0, 300)}…' : full);
      for (final p in paragraphs) {
        if (!_reading || !active) break;
        await say(p, mode: SpeakMode.queue);
      }
      if (_reading && active) await say('End of text.', mode: SpeakMode.queue);
    } catch (_) {
      await say('Reading failed.');
    } finally {
      _reading = false;
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  @override
  Future<void> onDoubleTap() async {
    quickRead = !quickRead;
    _lastQuickText = '';
    await say(quickRead ? 'Quick reading on. Short text will be read as it appears.' : 'Quick reading off.');
  }

  @override
  Future<bool> handle(Command c) async {
    if (c.intent == VoiceIntent.readText) {
      await readPage();
      return true;
    }
    if (c.intent == VoiceIntent.stop && _reading) {
      _reading = false;
      await speaker.stop();
      return true;
    }
    return false;
  }
}
