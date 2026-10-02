import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assist/core/vision/color_names.dart';
import 'package:vision_assist/core/vision/detection.dart';
import 'package:vision_assist/core/vision/embedding.dart';
import 'package:vision_assist/core/vision/frame.dart';
import 'package:vision_assist/core/vision/labels.dart';

void main() {
  group('frame sampling', () {
    test('rotation 90 maps upright corners to sensor corners', () {
      // Sensor 4x2, rotated 90 => upright 2x4.
      expect(uprightToSensor(1, 0, 4, 2, 90), 0 + (0 << 16)); // top-right upright = sensor (0,0)
      expect(uprightToSensor(0, 0, 4, 2, 90), 0 + (1 << 16));
      expect(uprightToSensor(0, 3, 4, 2, 90), 3 + (1 << 16));
    });

    test('NV21 round trip keeps colors close', () {
      final f = syntheticFrame(8, 8, (x, y) => x < 4 ? 0xD0202A : 0x2156C9);
      final left = sampleRgb(f, 1, 1), right = sampleRgb(f, 6, 6);
      expect(nearestColor(left).family, 'red');
      expect(nearestColor(right).family, 'blue');
    });

    test('rotated frame puts sensor-left content at upright top', () {
      // Sensor: left half red, right half blue. Rotated 90 cw for display:
      // sensor left column ends up at the upright top.
      final f = syntheticFrame(16, 8, (x, y) => x < 8 ? 0xD0202A : 0x2156C9, rotation: 90);
      expect(f.uprightWidth, 8);
      expect(f.uprightHeight, 16);
      expect(nearestColor(sampleRgb(f, 4, 2)).family, 'red');
      expect(nearestColor(sampleRgb(f, 4, 13)).family, 'blue');
    });

    test('letterbox tensor maps boxes back to upright coordinates', () {
      final f = syntheticFrame(64, 32, (x, y) => 0x808080);
      final t = Float32List(32 * 32 * 3);
      final lb = frameToTensor(f, t, 32);
      // 64x32 into 32: scale 0.5, padY 8.
      expect(lb.scale, closeTo(0.5, 1e-9));
      expect(lb.padY, closeTo(8, 1e-9));
      final r = lb.toUpright(0, 8, 32, 24);
      expect(r.left, closeTo(0, 1e-6));
      expect(r.top, closeTo(0, 1e-6));
      expect(r.right, closeTo(1, 1e-6));
      expect(r.bottom, closeTo(1, 1e-6));
      // Padding rows are gray 114.
      expect(t[0], closeTo(114 / 255, 1e-6));
    });
  });

  group('yolo decode', () {
    test('decodes and suppresses overlapping boxes', () {
      const n = 3, nc = 2;
      final out = Float32List((4 + nc) * n);
      void set(int i, double cx, double cy, double w, double h, double s0, double s1) {
        out[i] = cx;
        out[n + i] = cy;
        out[2 * n + i] = w;
        out[3 * n + i] = h;
        out[4 * n + i] = s0;
        out[5 * n + i] = s1;
      }

      set(0, 100, 100, 50, 50, 0.9, 0.1);
      set(1, 102, 101, 50, 50, 0.8, 0.1); // duplicate of 0
      set(2, 300, 300, 40, 40, 0.05, 0.7);
      const lb = LetterboxInfo(scale: 1, padX: 0, padY: 0, srcLeftPx: 0, srcTopPx: 0, uprightW: 400, uprightH: 400);
      final dets = decodeYolo(out, nc, n, ['a', 'b'], lb);
      expect(dets.length, 2);
      expect(dets.first.label, 'a');
      expect(dets.first.box.centerX, closeTo(0.25, 1e-6));
      expect(dets[1].label, 'b');
    });

    test('pkr labels map to rupee values', () {
      expect(pkrValue(pkrLabels[2]), 1000);
      expect(pkrValue('5000_PKR'), 5000);
    });
  });

  group('spoken descriptions', () {
    test('groups and orders detections', () {
      final dets = [
        const Detection(0, 'person', 0.9, NormRect(0.4, 0.2, 0.6, 0.9)),
        const Detection(0, 'person', 0.8, NormRect(0.45, 0.3, 0.55, 0.8)),
        const Detection(56, 'chair', 0.7, NormRect(0.0, 0.6, 0.2, 0.8)),
      ];
      expect(describeDetections(dets), '2 people ahead and a chair on your far left');
    });

    test('distance estimate is plausible for a person', () {
      const d = Detection(0, 'person', 0.9, NormRect(0.4, 0.2, 0.6, 0.6));
      final m = estimateDistanceMeters(d)!;
      expect(m, inInclusiveRange(2.5, 4.0));
    });

    test('articles and plurals', () {
      expect(withArticle('apple'), 'an apple');
      expect(pluralize('bus'), 'buses');
      expect(pluralize('cup'), 'cups');
    });
  });

  group('colors', () {
    test('names basic colors', () {
      expect(nearestColor(0x000000).name, 'black');
      expect(nearestColor(0xFFFFFF).family, 'white');
      expect(nearestColor(0xFF0000).family, 'red');
      expect(nearestColor(0x00FF00).family, 'green');
      expect(nearestColor(0x1B2545).name, 'navy blue');
    });

    test('dominant colors finds a two-tone mix', () {
      final samples = [
        ...List.filled(70, 0x1B2545),
        ...List.filled(30, 0xF5F5F5),
      ];
      final shares = dominantColors(samples);
      expect(shares.first.color.name, 'navy blue');
      expect(shares.first.fraction, closeTo(0.7, 0.01));
      expect(describeColorMix(shares), contains('with white'));
    });

    test('matching rules', () {
      final red = palette.firstWhere((c) => c.name == 'red');
      final pink = palette.firstWhere((c) => c.name == 'pink');
      final white = palette.firstWhere((c) => c.name == 'white');
      expect(colorsMatch(red, white).goesWell, isTrue);
      expect(colorsMatch(red, pink).goesWell, isFalse);
    });

    test('light level words', () {
      expect(lightLevel(10), 'very dark');
      expect(lightLevel(170), 'bright');
    });
  });

  group('embedding gallery', () {
    Float32List v(List<double> x) => l2Normalize(Float32List.fromList(x));

    test('matches the nearest entry above threshold', () {
      final gallery = [
        GalleryEntry(1, 'keys', [
          v([1, 0, 0]),
          v([0.9, 0.1, 0])
        ]),
        GalleryEntry(2, 'wallet', [
          v([0, 1, 0])
        ]),
      ];
      final m = bestGalleryMatch(v([0.95, 0.05, 0]), gallery, threshold: 0.8);
      expect(m?.entry.name, 'keys');
      expect(bestGalleryMatch(v([0, 0, 1]), gallery, threshold: 0.8), isNull);
    });

    test('bytes round trip', () {
      final e = v([1, 2, 3]);
      final back = embeddingFromBytes(embeddingToBytes(e));
      expect(back, e);
    });
  });

  group('rotated crops', () {
    test('undoes a counter-clockwise tilt', () {
      // A red dot that sits "above" the center after the content was rotated
      // 90 degrees counter-clockwise ends up on the left of the center.
      final f = syntheticFrame(64, 64, (x, y) => (x - 20).abs() < 4 && (y - 32).abs() < 4 ? 0xFF0000 : 0xFFFFFF);
      final t = Float32List(16 * 16 * 3);
      frameToTensor(f, t, 16, region: const NormRect(0.25, 0.25, 0.75, 0.75), letterbox: false, ccwDegrees: 90);
      // After straightening, the dot should be at the top-middle of the crop.
      int idx(int x, int y) => (y * 16 + x) * 3;
      final topMid = t[idx(8, 1)], centre = t[idx(8, 8)];
      expect(t[idx(8, 1) + 1], lessThan(0.3), reason: 'green channel low at top-middle (red dot)');
      expect(topMid, greaterThan(0.8));
      expect(t[idx(8, 8) + 1], greaterThan(0.8), reason: 'centre stays white');
      expect(centre, greaterThan(0.8));
    });
  });
}
