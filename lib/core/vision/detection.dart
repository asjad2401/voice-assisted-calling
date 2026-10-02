import 'dart:math' as math;
import 'dart:typed_data';

import 'frame.dart';

/// One detected object, with its box in normalized upright coordinates.
class Detection {
  final int classId;
  final String label;
  final double confidence;
  final NormRect box;

  const Detection(this.classId, this.label, this.confidence, this.box);

  Map<String, Object> toMessage() => {'c': classId, 'l': label, 'p': confidence, 'b': box.toList()};

  static Detection fromMessage(Map m) => Detection(
        m['c'] as int,
        m['l'] as String,
        (m['p'] as num).toDouble(),
        NormRect.fromList(m['b'] as List),
      );

  @override
  String toString() => 'Detection($label ${confidence.toStringAsFixed(2)} $box)';
}

/// Decodes a YOLOv8/YOLO11 TFLite head output of shape [1, 4 + nc, N] where
/// the first four rows are cx, cy, w, h in model-input pixels.
List<Detection> decodeYolo(
  Float32List out,
  int numClasses,
  int numAnchors,
  List<String> labels,
  LetterboxInfo lb, {
  double confThreshold = 0.35,
  double iouThreshold = 0.45,
  bool classAgnosticNms = false,
  int maxDetections = 30,
}) {
  final candidates = <Detection>[];
  for (int i = 0; i < numAnchors; i++) {
    double best = 0;
    int bestC = -1;
    for (int c = 0; c < numClasses; c++) {
      final s = out[(4 + c) * numAnchors + i];
      if (s > best) {
        best = s;
        bestC = c;
      }
    }
    if (best < confThreshold) continue;
    final cx = out[i], cy = out[numAnchors + i];
    final w = out[2 * numAnchors + i], h = out[3 * numAnchors + i];
    final box = lb.toUpright(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);
    if (box.area <= 0) continue;
    candidates.add(Detection(bestC, labels[bestC], best, box));
  }
  return nonMaxSuppression(candidates,
      iouThreshold: iouThreshold, classAgnostic: classAgnosticNms, maxDetections: maxDetections);
}

List<Detection> nonMaxSuppression(
  List<Detection> dets, {
  double iouThreshold = 0.45,
  bool classAgnostic = false,
  int maxDetections = 30,
}) {
  final sorted = [...dets]..sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <Detection>[];
  for (final d in sorted) {
    var suppressed = false;
    for (final k in kept) {
      if ((classAgnostic || k.classId == d.classId) && k.box.iou(d.box) > iouThreshold) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) {
      kept.add(d);
      if (kept.length >= maxDetections) break;
    }
  }
  return kept;
}

/// Horizontal direction word for a point in normalized x.
String directionWord(double cx) {
  if (cx < 0.2) return 'far left';
  if (cx < 0.4) return 'left';
  if (cx <= 0.6) return 'ahead';
  if (cx <= 0.8) return 'right';
  return 'far right';
}

/// Clock-face direction (10 to 2 o'clock) for a point in normalized x,
/// assuming roughly 60 degrees of horizontal field of view.
String clockDirection(double cx) {
  final deg = (cx - 0.5) * 60; // -30..30
  final hour = (12 + (deg / 30).round()) % 12;
  return '${hour == 0 ? 12 : hour} o\'clock';
}

/// Spoken phrase for a direction word, e.g. "on your left" / "ahead".
String directionPhrase(double cx) {
  final w = directionWord(cx);
  return w == 'ahead' ? 'ahead' : 'on your $w';
}

/// Rough real-world heights in meters for common COCO classes, used for a
/// pinhole-camera distance estimate.
const Map<String, double> _typicalHeights = {
  'person': 1.65,
  'bicycle': 1.0,
  'car': 1.5,
  'motorcycle': 1.1,
  'bus': 3.0,
  'truck': 3.0,
  'traffic light': 0.9,
  'fire hydrant': 0.7,
  'stop sign': 0.75,
  'bench': 0.85,
  'dog': 0.6,
  'cat': 0.3,
  'chair': 0.9,
  'couch': 0.85,
  'potted plant': 0.6,
  'bed': 0.6,
  'dining table': 0.75,
  'toilet': 0.75,
  'tv': 0.6,
  'refrigerator': 1.75,
  'suitcase': 0.65,
  'backpack': 0.5,
  'bottle': 0.25,
  'cup': 0.1,
  'laptop': 0.25,
  'oven': 0.9,
  'sink': 0.3,
};

/// Estimated distance in meters to [d], or null if unknown.
///
/// Assumes a vertical field of view of about 65 degrees for the upright
/// frame. Boxes cut by the top or bottom edge are reported as very close
/// only when they also fill most of the frame.
double? estimateDistanceMeters(Detection d, {double verticalFovDeg = 65}) {
  final realH = _typicalHeights[d.label];
  final h = d.box.height;
  if (h <= 0.01) return null;
  final focal = 0.5 / math.tan(verticalFovDeg * math.pi / 360);
  final touchesEdge = d.box.top < 0.02 || d.box.bottom > 0.98;
  if (realH == null) {
    // Unknown size: use apparent size only.
    if (h > 0.8) return 0.5;
    return null;
  }
  final dist = realH * focal / h;
  if (touchesEdge && h > 0.85) return math.min(dist, 0.8);
  return dist;
}

/// "about 2 meters" style phrasing.
String distancePhrase(double meters) {
  if (meters < 1) return 'very close';
  if (meters < 1.5) return 'about 1 meter away';
  if (meters > 10) return 'far away';
  return 'about ${meters.round()} meters away';
}

/// Groups detections by label and describes them with counts and
/// directions, e.g. "2 people ahead, a chair on your left".
String describeDetections(List<Detection> dets, {int maxItems = 6}) {
  if (dets.isEmpty) return '';
  final byLabel = <String, List<Detection>>{};
  for (final d in dets) {
    byLabel.putIfAbsent(d.label, () => []).add(d);
  }
  final entries = byLabel.entries.toList()
    ..sort((a, b) {
      // Bigger (closer) things first.
      final aa = a.value.map((d) => d.box.area).reduce(math.max);
      final bb = b.value.map((d) => d.box.area).reduce(math.max);
      return bb.compareTo(aa);
    });
  final parts = <String>[];
  for (final e in entries.take(maxItems)) {
    final n = e.value.length;
    final meanX = e.value.map((d) => d.box.centerX).reduce((a, b) => a + b) / n;
    final noun = n == 1 ? withArticle(e.key) : '$n ${pluralize(e.key)}';
    parts.add('$noun ${directionPhrase(meanX)}');
  }
  return joinSpoken(parts);
}

String withArticle(String noun) {
  const vowels = 'aeiou';
  return '${vowels.contains(noun[0].toLowerCase()) ? 'an' : 'a'} $noun';
}

String pluralize(String noun) {
  const irregular = {
    'person': 'people',
    'mouse': 'mice',
    'knife': 'knives',
    'sheep': 'sheep',
    'skis': 'skis',
    'scissors': 'scissors',
    'wine glass': 'wine glasses',
    'bus': 'buses',
    'couch': 'couches',
    'bench': 'benches',
    'sandwich': 'sandwiches',
    'toothbrush': 'toothbrushes',
  };
  if (irregular.containsKey(noun)) return irregular[noun]!;
  if (noun.endsWith('s') || noun.endsWith('x') || noun.endsWith('ch')) {
    return '${noun}es';
  }
  return '${noun}s';
}

String joinSpoken(List<String> parts) {
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.first;
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}
