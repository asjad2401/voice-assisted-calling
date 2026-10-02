import 'package:flutter/material.dart';

import '../../core/commands.dart';
import '../module.dart';
import 'call_controller.dart';
import 'call_platform.dart';
import 'contacts_service.dart';

/// Voice dialing. Incoming calls are handled app-wide by [CallController].
class CallsModule extends AssistModule {
  @override
  String get id => 'calls';
  @override
  String get title => 'Calls';
  @override
  IconData get icon => Icons.call;
  @override
  Color get color => const Color(0xFF1E3A8A);
  @override
  String get hint => 'Tap and say a contact name to call them. Double tap to call back the last person you called.';
  @override
  String get help =>
      'Calls mode. Tap, then say the name of a contact; I will confirm before dialing. Calls use the speakerphone. Tap the screen during a call to hang up. '
      'When someone calls you, I let the phone ring briefly, then say who is calling; say answer or ignore, or tap anywhere to answer. '
      'From any mode you can also say "call" followed by a name. For incoming call announcements this app must be your default phone app; say "set up calls" to do that.';
  @override
  String get tapLabel => 'Call a contact';
  @override
  String get doubleTapLabel => 'Call back last person';

  @override
  bool get usesCamera => false;

  final calls = CallController.instance;

  @override
  Future<void> onEnter() async {
    status = 'Tap to call someone';
    ContactsService.instance.loadContacts();
  }

  @override
  Future<void> onTap() async {
    if (calls.state == CallState.listeningForName || calls.state == CallState.confirming) {
      return calls.cancelPending();
    }
    status = 'Listening for a name…';
    await calls.dialByVoice();
    status = 'Tap to call someone';
  }

  @override
  Future<void> onDoubleTap() async {
    final name = calls.lastDialedName, number = calls.lastDialedNumber;
    if (name == null || number == null) return say('You have not made a call with this app yet.');
    if (await host.confirm('Call $name again?')) await calls.placeCall(name, number);
  }

  @override
  Future<bool> handle(Command c) async {
    if (c.intent == VoiceIntent.call) {
      await calls.dialByVoice(c.arg);
      return true;
    }
    final raw = normalizeUtterance(c.raw);
    if (raw.contains('set up calls') || raw.contains('default phone') || raw.contains('default dialer')) {
      await say(
          'I will open the Android setting. Choose this app as your phone app. A sighted helper may be needed for this one screen.');
      await CallPlatform.instance.requestPhoneAccountSetup();
      return true;
    }
    return false;
  }
}
