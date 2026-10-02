import 'package:flutter_test/flutter_test.dart';
import 'package:vision_assist/core/commands.dart';
import 'package:vision_assist/core/nav/motion.dart';
import 'package:vision_assist/core/nav/route.dart';

void main() {
  group('command parser', () {
    final cases = <String, (VoiceIntent, String?)>{
      'Call Ahmed please': (VoiceIntent.call, 'ahmed'),
      'read this for me': (VoiceIntent.readText, null),
      "What's in front of me?": (VoiceIntent.whatsAhead, null),
      'describe the scene': (VoiceIntent.describeScene, null),
      'how much money is this': (VoiceIntent.currency, null),
      'what color is this': (VoiceIntent.color, null),
      'find my keys': (VoiceIntent.findObject, 'keys'),
      'where are my glasses': (VoiceIntent.findObject, 'glasses'),
      'save this as my wallet': (VoiceIntent.saveObject, 'wallet'),
      'save this place as kitchen': (VoiceIntent.saveLandmark, 'kitchen'),
      'take me to the bathroom': (VoiceIntent.navigateTo, 'bathroom'),
      'record route to bedroom': (VoiceIntent.recordRoute, 'bedroom'),
      'where am i': (VoiceIntent.whereAmI, null),
      "who's here": (VoiceIntent.whoIsHere, null),
      'save this person as Sara': (VoiceIntent.savePerson, 'sara'),
      'help me': (VoiceIntent.emergency, null),
      'emergency': (VoiceIntent.emergency, null),
      'read my medical information': (VoiceIntent.medicalInfo, null),
      'where did I leave my keys': (VoiceIntent.whereLast, 'keys'),
      'what did i do today': (VoiceIntent.activityToday, null),
      'what time is it': (VoiceIntent.time, null),
      'speak faster': (VoiceIntent.faster, null),
      'yes': (VoiceIntent.yes, null),
      'no': (VoiceIntent.no, null),
      'does this match': (VoiceIntent.matchClothes, null),
      'open currency': (VoiceIntent.currency, null),
      'places mode': (VoiceIntent.openMode, 'places'),
      'blah blah': (VoiceIntent.unknown, null),
    };
    cases.forEach((utterance, expected) {
      test(utterance, () {
        final c = parseCommand(utterance);
        expect(c.intent, expected.$1);
        if (expected.$2 != null) expect(c.arg, expected.$2);
      });
    });

    test('fuzzy name matching', () {
      expect(matchName('key', ['keys', 'wallet']), 'keys');
      expect(matchName('the kitchen', ['Kitchen', 'Bedroom']), 'Kitchen');
      expect(matchName('zebra', ['keys', 'wallet']), isNull);
    });
  });

  group('motion', () {
    test('step detector counts periodic peaks', () {
      final d = StepDetector();
      int t = 0;
      // 10 steps at ~2 Hz: 0.5 s per step at 50 Hz sampling.
      for (int s = 0; s < 10; s++) {
        for (int i = 0; i < 25; i++) {
          final z = i < 5 ? 13.5 : 9.3;
          d.add(0, 0, z, t);
          t += 20;
        }
      }
      expect(d.steps, inInclusiveRange(9, 10));
    });

    test('heading when phone is flat and pointing north', () {
      // Flat, screen up: gravity on +Z; magnetic field points north (+Y) and down.
      final h = headingDegrees(0, 0, 9.8, 0, 20, -40)!;
      expect(h, closeTo(0, 1));
    });

    test('heading when phone is upright facing east', () {
      // Upright portrait: gravity along +Y. Camera (-Z) points east.
      // Right edge (+X) points south, so north is -X; field also points down (-Y).
      final h = headingDegrees(0, 9.8, 0, -20, -40, 0)!;
      expect(h, closeTo(90, 1));
    });

    test('angle helpers', () {
      expect(angleDiff(10, 350), closeTo(20, 1e-9));
      expect(angleDiff(350, 10), closeTo(-20, 1e-9));
      expect(circularMean([350, 10]), anyOf(closeTo(0, 1e-6), closeTo(360, 1e-6)));
      expect(turnPhrase(90), 'turn right');
      expect(turnPhrase(-30), 'turn slightly left');
      expect(turnPhrase(170), 'turn around');
    });
  });

  group('routes', () {
    test('recorder splits legs at a turn', () {
      final r = RouteRecorder();
      for (int i = 0; i < 10; i++) {
        r.addStep(0);
      }
      for (int i = 0; i < 6; i++) {
        r.addStep(90);
      }
      final segs = r.finish();
      expect(segs.length, 2);
      expect(segs[0].steps + segs[1].steps, 16);
      expect(segs[0].heading, closeTo(0, 1));
      expect(segs[1].heading, closeTo(90, 1));
    });

    test('reverse route flips order and heading', () {
      const route = SavedRoute(from: 'A', to: 'B', segments: [RouteSegment(10, 0), RouteSegment(5, 90)]);
      final back = route.reversed();
      expect(back.from, 'B');
      expect(back.segments.first.steps, 5);
      expect(back.segments.first.heading, 270);
      expect(route.describe(), '10 steps, turn right, 5 steps');
    });

    test('guide walks through turns to arrival', () {
      const route = SavedRoute(from: 'A', to: 'B', segments: [RouteSegment(5, 0), RouteSegment(4, 90)]);
      final g = RouteGuide(route);
      expect(g.start(0).message, contains('walk about 5 steps'));
      final events = <GuideEvent>[];
      for (int i = 0; i < 5; i++) {
        final e = g.onStep(0);
        if (e != null) events.add(e);
      }
      expect(events.last.kind, GuideEventKind.turn);
      expect(events.last.message, 'Turn right now.');
      expect(g.onHeading(85)?.kind, GuideEventKind.aligned);
      GuideEvent? last;
      for (int i = 0; i < 4; i++) {
        last = g.onStep(90) ?? last;
      }
      expect(last?.kind, GuideEventKind.arrived);
      expect(g.arrived, isTrue);
    });
  });

  group('route graph', () {
    const ab = SavedRoute(from: 'Bedroom', to: 'Hall', segments: [RouteSegment(6, 0)]);
    const bc = SavedRoute(from: 'Hall', to: 'Kitchen', segments: [RouteSegment(8, 90)]);
    test('chains routes across places', () {
      final r = findRoute([ab, bc], 'bedroom', 'kitchen')!;
      expect(r.totalSteps, 14);
      expect(r.segments.length, 2);
    });
    test('uses routes in reverse', () {
      final r = findRoute([ab, bc], 'Kitchen', 'Bedroom')!;
      expect(r.segments.first.heading, 270);
      expect(r.to, 'Bedroom');
    });
    test('null when not connected', () {
      expect(findRoute([ab], 'Bedroom', 'Garage'), isNull);
    });
  });
}
