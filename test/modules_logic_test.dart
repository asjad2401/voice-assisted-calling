import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assist/core/storage/store.dart';
import 'package:vision_assist/core/vision/announcer.dart';
import 'package:vision_assist/core/vision/color_names.dart';
import 'package:vision_assist/core/vision/detection.dart';
import 'package:vision_assist/core/vision/frame.dart';
import 'package:vision_assist/modules/activity_module.dart';
import 'package:vision_assist/modules/currency_module.dart';
import 'package:vision_assist/modules/emergency_module.dart';
import 'package:vision_assist/modules/explore_module.dart';
import 'package:vision_assist/modules/objects_module.dart';
import 'package:vision_assist/modules/obstacle_module.dart';
import 'package:vision_assist/modules/text_module.dart';

void main() {
  group('currency phrasing', () {
    test('rupees formats thousands', () {
      expect(rupees(5000), '5,000 rupees');
      expect(rupees(100), '100 rupees');
      expect(rupees(12500), '12,500 rupees');
    });

    test('describeNotes totals several notes', () {
      final notes = [
        const Detection(5, '500_PKR', 0.9, NormRect(0, 0, 0.5, 0.5)),
        const Detection(1, '100_PKR', 0.8, NormRect(0.5, 0.5, 1, 1)),
      ];
      expect(describeNotes(notes), '2 notes: 500 and 100. Total 600 rupees.');
      expect(describeNotes(const []), 'No currency note found.');
    });
  });

  group('obstacles', () {
    test('a close person in the path outranks a far chair at the side', () {
      final hazards = rankHazards([
        const Detection(56, 'chair', 0.8, NormRect(0.0, 0.5, 0.15, 0.6)),
        const Detection(0, 'person', 0.9, NormRect(0.35, 0.0, 0.65, 0.99)),
      ]);
      expect(hazards.first.detection.label, 'person');
      expect(hazards.first.inPath, isTrue);
      expect(hazards.first.urgency, greaterThan(0.7));
    });

    test('irrelevant objects are ignored', () {
      expect(rankHazards([const Detection(41, 'cup', 0.9, NormRect(0.4, 0.4, 0.6, 0.6))]), isEmpty);
    });
  });

  group('text framing', () {
    test('cut-off text gives direction', () {
      expect(framingAdvice([const NormRect(0.0, 0.3, 0.6, 0.5)]), contains('left'));
      expect(framingAdvice([const NormRect(0.3, 0.3, 1.0, 0.5)]), contains('right'));
      expect(framingAdvice([const NormRect(0.2, 0.2, 0.8, 0.8)]), isNull);
      expect(framingAdvice([const NormRect(0.45, 0.45, 0.5, 0.5)]), contains('closer'));
    });
  });

  group('scene description', () {
    test('combines place labels, objects, light and text', () {
      final s = composeSceneDescription(
        objects: const [
          Detection(56, 'chair', 0.8, NormRect(0.0, 0.4, 0.3, 0.9)),
          Detection(60, 'dining table', 0.7, NormRect(0.3, 0.5, 0.8, 0.9)),
        ],
        labels: const [('Kitchen', 0.8), ('Chair', 0.7), ('Wood', 0.65)],
        textWordCount: 5,
        luma: 150,
        dominant: [ColorShare(palette.firstWhere((p) => p.name == 'beige'), 0.6, 0xD8C3A5)],
      );
      expect(s, startsWith('This looks like a kitchen.'));
      expect(s, contains('a chair on your'));
      expect(s, contains('lighting is bright'));
      expect(s, contains('some text visible'));
      expect(s, isNot(contains('I think I see chair')));
    });
  });

  group('announcer', () {
    test('needs two sightings and then respects cooldown', () {
      final a = Announcer<String>(minHits: 2, cooldown: const Duration(seconds: 10));
      final t0 = DateTime(2026, 1, 1, 12);
      expect(a.update({'chair': ('chair', 'left')}, t0), isEmpty);
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(milliseconds: 300))), ['chair']);
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 1))), isEmpty);
      // Still in view: stays quiet until the cooldown passes.
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 4))), isEmpty);
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 8))), isEmpty);
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 11))), ['chair']);
      // Gone for a while, then back: needs two sightings again.
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 30))), isEmpty);
      expect(a.update({'chair': ('chair', 'left')}, t0.add(const Duration(seconds: 31))), ['chair']);
    });
  });

  group('emergency', () {
    test('SOS message includes map link and medical basics', () {
      final p = EmergencyProfile()
        ..name = 'Asjad'
        ..bloodGroup = 'B+'
        ..conditions = 'diabetes';
      final m = sosMessage(p, lat: 31.5204, lng: 74.3587, accuracyM: 12, at: DateTime(2026, 1, 1, 9, 5));
      expect(m, startsWith('EMERGENCY: Asjad needs help.'));
      expect(m, contains('https://maps.google.com/?q=31.520400,74.358700'));
      expect(m, contains('within about 12 m'));
      expect(m, contains('Blood group B+'));
      expect(m, contains('09:05'));
    });

    test('profile round trips through JSON', () {
      final p = EmergencyProfile()
        ..name = 'A'
        ..contacts = [const EmergencyContact('Mom', '0300')];
      final back = EmergencyProfile.fromJson(p.toJson());
      expect(back.contacts.single.name, 'Mom');
      expect(back.summary(), contains('Emergency contacts: Mom, 0300.'));
    });
  });

  group('activity', () {
    test('summarizes a day', () {
      final t = DateTime(2026, 1, 1, 10);
      final events = [
        ActivityEvent(1, t, 'text', 'read', 'x', null),
        ActivityEvent(2, t, 'text', 'read', 'y', null),
        ActivityEvent(3, t, 'people', 'person', 'Saw Sara', 'sara'),
        ActivityEvent(4, t, 'objects', 'sighting', 'Saw your keys', 'keys'),
      ];
      expect(summarizeEvents(events), 'Today you read 2 texts, met Sara and spotted your keys.');
      expect(summarizeEvents(const []), contains('nothing'));
    });

    test('timeAgo wording', () {
      final now = DateTime(2026, 1, 2, 15, 0);
      expect(timeAgo(now.subtract(const Duration(minutes: 5)), now), '5 minutes ago');
      expect(timeAgo(DateTime(2026, 1, 2, 9, 30), now), 'today at 9:30 AM');
      expect(timeAgo(DateTime(2026, 1, 1, 21, 5), now), 'yesterday at 9:05 PM');
    });
  });
}
