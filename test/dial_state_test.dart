import 'package:flutter_test/flutter_test.dart';
import 'package:blind_call_assistant/services/call_platform.dart';

void main() {
  group('CallEvent Data Deserialization Tests', () {
    test('CallEvent.fromMap parses incoming call map correctly', () {
      final map = {
        'type': 'incoming',
        'number': '+15550199',
        'callerName': 'John Doe',
      };

      final event = CallEvent.fromMap(map);
      expect(event.type, equals('incoming'));
      expect(event.number, equals('+15550199'));
      expect(event.callerName, equals('John Doe'));
    });

    test('CallEvent.fromMap handles ended call event map', () {
      final map = {'type': 'ended'};
      final event = CallEvent.fromMap(map);
      expect(event.type, equals('ended'));
      expect(event.number, isNull);
      expect(event.callerName, isNull);
    });

    test('CallEvent.fromMap handles answered call event map', () {
      final map = {'type': 'answered'};
      final event = CallEvent.fromMap(map);
      expect(event.type, equals('answered'));
    });
  });
}
