import 'package:flutter/material.dart';

import '../core/commands.dart';
import '../core/cues.dart';
import '../core/speech/listener.dart';
import '../core/speech/speaker.dart';
import '../core/storage/store.dart';
import '../core/vision/frame.dart';

/// Services the shell provides to every mode.
abstract class ModuleHost {
  /// Speaks [prompt], then listens for a spoken answer.
  Future<String?> ask(String prompt, {Duration timeout = const Duration(seconds: 8)});

  /// Asks a yes/no question; true only on a clear yes.
  Future<bool> confirm(String prompt);

  /// Switches to another mode, optionally handing it a command.
  Future<void> openMode(String id, {Command? command});

  /// Finds a mode by id.
  AssistModule? module(String id);

  /// Name of the place the user was last recognized at, if recent.
  String? get currentPlace;
  set currentPlace(String? name);
}

/// One feature area of the app ("mode"). The shell owns gestures and
/// shows the active mode full-screen; the mode reacts to taps, camera
/// frames and voice commands.
abstract class AssistModule extends ChangeNotifier {
  late ModuleHost host;

  String get id;
  String get title;
  IconData get icon;
  Color get color;

  /// One-sentence usage hint spoken when the mode opens.
  String get hint;

  /// Longer help for "help" in this mode.
  String get help;

  /// Accessible labels for the two main actions.
  String get tapLabel;
  String get doubleTapLabel;

  /// Whether the camera preview and frame stream are needed.
  bool get usesCamera => true;

  /// Whether this mode wants live frames right now.
  bool get wantsFrames => usesCamera;

  bool active = false;
  String _status = '';
  String get status => _status;
  set status(String s) {
    _status = s;
    notifyListeners();
  }

  Speaker get speaker => Speaker.instance;
  SpeechInput get listener => SpeechInput.instance;
  Cues get cues => Cues.instance;
  Store get store => Store.instance;

  Future<void> say(String text, {SpeakMode mode = SpeakMode.interrupt}) => speaker.speak(text, mode: mode);

  Future<void> log(String kind, String text, {String? subject}) => store.logEvent(id, kind, text, subject: subject);

  Future<void> onEnter() async {}
  Future<void> onExit() async {}
  Future<void> onFrame(NV21Frame frame) async {}
  Future<void> onTap();
  Future<void> onDoubleTap();

  /// Returns true if the command was handled by this mode.
  Future<bool> handle(Command c) async => false;
}
