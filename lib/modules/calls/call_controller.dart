import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/cues.dart';
import '../../core/speech/listener.dart';
import '../../core/speech/speaker.dart';
import '../../core/storage/store.dart';
import 'call_platform.dart';
import 'contacts_service.dart';

enum CallState { idle, listeningForName, confirming, incoming, inCall }

/// Voice dialing and voice answering, ported from the original Blind Call
/// Assistant screen into an app-wide controller so an incoming call takes
/// over whatever mode is open.
class CallController extends ChangeNotifier {
  CallController._();
  static final CallController instance = CallController._();

  CallState state = CallState.idle;
  String target = '';
  String? lastDialedName;
  String? lastDialedNumber;
  StreamSubscription<CallEvent>? _sub;

  final _speaker = Speaker.instance;
  final _listener = SpeechInput.instance;

  bool get takesOverScreen => state == CallState.incoming || state == CallState.inCall;

  void Function()? onCallStarted;
  void Function()? onCallFinished;

  void start() {
    _sub ??= CallPlatform.instance.events.listen(_onEvent, onError: (_) {});
  }

  void _set(CallState s, [String? t]) {
    final wasTakeover = takesOverScreen;
    state = s;
    if (t != null) target = t;
    notifyListeners();
    if (!wasTakeover && takesOverScreen) onCallStarted?.call();
    if (wasTakeover && !takesOverScreen) onCallFinished?.call();
  }

  /// Asks for a name (unless given), confirms, then dials.
  Future<void> dialByVoice([String? spokenName]) async {
    if (state != CallState.idle) return;
    _set(CallState.listeningForName);
    try {
      var heard = spokenName;
      if (heard == null) {
        await _speaker.speak('Who do you want to call?');
        await Cues.instance.listeningCue();
        heard = await _listener.listenOnce(timeout: const Duration(seconds: 10));
      }
      if (state != CallState.listeningForName) return;
      if (heard == null || heard.trim().isEmpty) {
        await _speaker.speak("I didn't hear a name. Tap to try again.");
        return;
      }
      final match = await ContactsService.instance.findBestMatchAsync(heard);
      if (match == null) {
        await _speaker.speak("I couldn't find $heard in your contacts.");
        return;
      }
      _set(CallState.confirming, match.displayName);
      await _speaker.speak('Call ${match.displayName}? Say yes to confirm.');
      if (state != CallState.confirming) return;
      await Cues.instance.listeningCue();
      final answer = await _listener.listenOnce(timeout: const Duration(seconds: 6));
      if (state != CallState.confirming) return;
      if (!isAffirmative(answer) && !(answer ?? '').toLowerCase().contains('call')) {
        await _speaker.speak('Call cancelled.');
        return;
      }
      await placeCall(match.displayName, match.phoneNumber);
    } finally {
      if (state == CallState.listeningForName || state == CallState.confirming) _set(CallState.idle, '');
    }
  }

  Future<void> placeCall(String name, String number) async {
    lastDialedName = name;
    lastDialedNumber = number;
    _set(CallState.inCall, name);
    await _listener.cancel();
    await _speaker.speak('Calling $name.');
    await Store.instance.logEvent('calls', 'call', 'Called $name', subject: name);
    try {
      await CallPlatform.instance.placeCall(number);
      await CallPlatform.instance.enableSpeakerphone();
    } catch (_) {
      await _speaker.speak('Unable to place the call.');
      _set(CallState.idle, '');
    }
  }

  Future<void> cancelPending() async {
    if (state == CallState.listeningForName || state == CallState.confirming) {
      await _listener.cancel();
      await _speaker.stop();
      _set(CallState.idle, '');
      await _speaker.speak('Cancelled.');
    }
  }

  /// The single full-screen tap during a call: answer if ringing, else hang up.
  Future<void> onTakeoverTap() async {
    if (state == CallState.incoming) {
      await answer();
    } else if (state == CallState.inCall) {
      await hangUp();
    }
  }

  Future<void> answer() async {
    await _listener.cancel();
    await _speaker.stop();
    await CallPlatform.instance.answerCall();
    await CallPlatform.instance.enableSpeakerphone();
    _set(CallState.inCall);
    await _speaker.speak('Call answered.');
  }

  Future<void> reject() async {
    await _listener.cancel();
    await _speaker.stop();
    await CallPlatform.instance.rejectCall();
    _set(CallState.idle, '');
    await _speaker.speak('Call declined.');
  }

  Future<void> hangUp() async {
    await _listener.cancel();
    await _speaker.stop();
    await CallPlatform.instance.rejectCall();
    _set(CallState.idle, '');
    await _speaker.speak('Call ended.');
  }

  void _onEvent(CallEvent e) {
    switch (e.type) {
      case 'incoming':
        _handleIncoming(e);
        break;
      case 'dialing':
        if (state != CallState.inCall) _set(CallState.inCall, target.isEmpty ? 'Dialing' : target);
        CallPlatform.instance.enableSpeakerphone();
        break;
      case 'answered':
        CallPlatform.instance.enableSpeakerphone();
        if (state != CallState.inCall) _set(CallState.inCall);
        break;
      case 'ended':
      case 'rejected':
        if (takesOverScreen) {
          _listener.cancel();
          _set(CallState.idle, '');
          _speaker.speak('Call ended.');
        }
        break;
    }
  }

  Future<void> _handleIncoming(CallEvent e) async {
    if (state == CallState.incoming) return;
    await _speaker.stop();
    var caller = 'Unknown caller';
    if (e.number != null && e.number!.isNotEmpty) {
      final c = await ContactsService.instance.findContactByNumberAsync(e.number!);
      if (c != null && c.displayName.isNotEmpty) {
        caller = c.displayName;
      } else if (e.callerName?.isNotEmpty ?? false) {
        caller = e.callerName!;
      } else {
        caller = 'number ${e.number!.split('').join(' ')}';
      }
    } else if (e.callerName?.isNotEmpty ?? false) {
      caller = e.callerName!;
    }
    _set(CallState.incoming, caller);
    await Store.instance.logEvent('calls', 'incoming', 'Call from $caller', subject: caller);
    // Let the phone ring normally for a moment before talking over it.
    await Future.delayed(const Duration(seconds: 3));
    if (state != CallState.incoming) return;
    await _speaker.speak('Call from $caller. Say answer or ignore, or tap the screen to answer.');
    if (state != CallState.incoming) return;
    await _listener.listenForKeywords(
      groups: const {
        'answer': ['answer', 'pick', 'pickup', 'yes', 'accept', 'hello', 'attend', 'receive', 'take'],
        'ignore': ['ignore', 'reject', 'decline', 'no', 'cut', 'cancel', 'busy', 'later'],
      },
      onMatched: (g) {
        if (state != CallState.incoming) return;
        g == 'answer' ? answer() : reject();
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
