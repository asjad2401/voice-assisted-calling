import 'package:flutter/services.dart';

/// Event emitted from the native side when call state changes.
class CallEvent {
  final String type; // 'incoming' | 'answered' | 'rejected' | 'ended'
  final String? number;
  final String? callerName; // resolved on native side if available

  CallEvent(this.type, {this.number, this.callerName});

  factory CallEvent.fromMap(Map<dynamic, dynamic> m) => CallEvent(
        m['type'] as String,
        number: m['number'] as String?,
        callerName: m['callerName'] as String?,
      );
}

/// Bridges to native Android code for placing calls, checking default dialer role,
/// answering/rejecting calls, enforcing speakerphone mode, and receiving call status events.
class CallPlatform {
  CallPlatform._internal();
  static final CallPlatform instance = CallPlatform._internal();

  static const _methodChannel = MethodChannel('blind_call_assistant/call');
  static const _eventChannel = EventChannel('blind_call_assistant/call_events');

  Stream<CallEvent>? _events;

  Stream<CallEvent> get events {
    _events ??= _eventChannel.receiveBroadcastStream().map((e) => CallEvent.fromMap(e as Map));
    return _events!;
  }

  Future<void> placeCall(String phoneNumber) => _methodChannel.invokeMethod('placeCall', {'number': phoneNumber});

  Future<void> answerCall() => _methodChannel.invokeMethod('answerCall');

  Future<void> rejectCall() => _methodChannel.invokeMethod('rejectCall');

  /// Forces audio routing through the device Speakerphone.
  Future<void> enableSpeakerphone() async {
    try {
      await _methodChannel.invokeMethod('enableSpeakerphone');
    } catch (_) {}
  }

  /// Checks whether the app is currently set as the default dialer / calling account.
  Future<bool> isDefaultDialer() async {
    try {
      final bool res = await _methodChannel.invokeMethod('isDefaultDialer') ?? false;
      return res;
    } catch (_) {
      return false;
    }
  }

  /// Prompts the user through Android's system default dialer picker
  /// so this app can register as a calling account and receive InCallService callbacks.
  Future<void> requestPhoneAccountSetup() => _methodChannel.invokeMethod('requestPhoneAccountSetup');
}
