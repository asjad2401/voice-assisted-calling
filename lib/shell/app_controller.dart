import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/cues.dart';
import '../core/settings.dart';
import '../core/speech/listener.dart';
import '../core/speech/speaker.dart';
import '../core/vision/vision_worker.dart';
import '../modules/activity_module.dart';
import '../modules/calls/call_controller.dart';
import '../modules/calls/calls_module.dart';
import '../modules/color_module.dart';
import '../modules/currency_module.dart';
import '../modules/emergency_module.dart';
import '../modules/explore_module.dart';
import '../modules/module.dart';
import '../modules/objects_module.dart';
import '../modules/obstacle_module.dart';
import '../modules/people_module.dart';
import '../modules/places_module.dart';
import '../modules/text_module.dart';

/// Which mode handles each intent when it is spoken from anywhere.
const Map<VoiceIntent, String> intentHome = {
  VoiceIntent.describeScene: 'explore',
  VoiceIntent.whatsAhead: 'explore',
  VoiceIntent.obstacles: 'obstacles',
  VoiceIntent.readText: 'text',
  VoiceIntent.currency: 'currency',
  VoiceIntent.color: 'color',
  VoiceIntent.lightLevel: 'color',
  VoiceIntent.clothing: 'color',
  VoiceIntent.matchClothes: 'color',
  VoiceIntent.whoIsHere: 'people',
  VoiceIntent.savePerson: 'people',
  VoiceIntent.findObject: 'objects',
  VoiceIntent.saveObject: 'objects',
  VoiceIntent.whereAmI: 'places',
  VoiceIntent.saveLandmark: 'places',
  VoiceIntent.navigateTo: 'places',
  VoiceIntent.recordRoute: 'places',
  VoiceIntent.stopNavigation: 'places',
  VoiceIntent.call: 'calls',
  VoiceIntent.emergency: 'emergency',
  VoiceIntent.medicalInfo: 'emergency',
  VoiceIntent.activityToday: 'activity',
  VoiceIntent.whereLast: 'activity',
  VoiceIntent.clearLog: 'activity',
};

/// Owns the list of modes, the active mode, gestures and voice commands.
class AppController extends ChangeNotifier implements ModuleHost {
  AppController() {
    for (final m in modules) {
      m.host = this;
    }
  }

  final List<AssistModule> modules = [
    ExploreModule(),
    ObstacleModule(),
    TextModule(),
    CurrencyModule(),
    ColorModule(),
    PeopleModule(),
    ObjectsModule(),
    PlacesModule(),
    CallsModule(),
    EmergencyModule(),
    ActivityModule(),
  ];

  int index = 0;
  bool listeningForCommand = false;
  bool ready = false;
  String caption = '';
  String? _currentPlace;
  DateTime? _placeTime;
  StreamSubscription<UserAccelerometerEvent>? _shakeSub;
  final List<int> _shakeTimes = [];

  AssistModule get active => modules[index];
  final speaker = Speaker.instance;
  final calls = CallController.instance;

  @override
  AssistModule? module(String id) {
    for (final m in modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  String? get currentPlace {
    if (_placeTime != null && DateTime.now().difference(_placeTime!).inMinutes > 15) return null;
    return _currentPlace;
  }

  @override
  set currentPlace(String? name) {
    _currentPlace = name;
    _placeTime = DateTime.now();
  }

  // ---- startup -------------------------------------------------------------

  Future<void> start() async {
    await Settings.instance.load();
    await speaker.init(rate: Settings.instance.speechRate);
    Cues.instance.hapticsEnabled = Settings.instance.haptics;
    speaker.onCaption = (t) {
      caption = t;
      notifyListeners();
    };
    calls.onCallStarted = _onCallStarted;
    calls.onCallFinished = _onCallFinished;
    calls.start();
    await (module('emergency') as EmergencyModule).load();
    unawaited(VisionWorker.instance.start().catchError((_) {}));
    _startShakeDetection();

    final firstRun = !Settings.instance.tutorialDone;
    if (firstRun) {
      await speaker.speak('Welcome to Vision Assist, your offline assistant. First I need a few permissions. '
          'A sighted helper can tap allow, or you can find the allow button near the bottom of the screen.');
    }
    await _requestPermissions(spoken: firstRun);
    final start = modules.indexWhere((m) => m.id == Settings.instance.lastModeId);
    index = start < 0 ? 0 : start;
    ready = true;
    notifyListeners();
    if (firstRun) {
      await tutorial();
      Settings.instance.tutorialDone = true;
      await Settings.instance.save();
    }
    await _enter(active, announce: !firstRun);
  }

  Future<void> _requestPermissions({bool spoken = false}) async {
    final wanted = [
      Permission.camera,
      Permission.microphone,
      Permission.contacts,
      Permission.phone,
      Permission.locationWhenInUse,
      Permission.sms,
    ];
    final statuses = await wanted.request();
    final denied = statuses.entries.where((e) => !e.value.isGranted).map((e) => e.key).toList();
    if (denied.isEmpty || !spoken) return;
    final names = denied.map(_permissionName).toList();
    await speaker.speak('Some permissions were not allowed: ${names.join(', ')}. Related features will not work. '
        'Say "permissions" at any time to open settings and allow them.');
  }

  String _permissionName(Permission p) {
    if (p == Permission.camera) return 'camera, needed for all seeing features';
    if (p == Permission.microphone) return 'microphone, for voice commands';
    if (p == Permission.contacts) return 'contacts, for calling';
    if (p == Permission.phone) return 'phone, for calling';
    if (p == Permission.locationWhenInUse) return 'location, for emergency alerts';
    if (p == Permission.sms) return 'text messages, for emergency alerts';
    return p.toString();
  }

  Future<void> tutorial() async {
    const steps = [
      'Here is how it works. The app has eleven modes. Swipe left or right anywhere on the screen to move between them. Each mode tells you its name when it opens.',
      'Tap once anywhere for the main action of the mode, such as describing what is in front of you. Double tap for the second action.',
      'Press and hold anywhere to give a voice command after the beep. For example: "read this", "how much money is this", "find my keys", "call Ahmed", "where am I", or "help".',
      'Swipe up to repeat the last thing I said. Swipe down to stop me talking.',
      'In an emergency, say "help me", or shake the phone hard three times, and I will alert your emergency contacts.',
      'Everything works without internet. For the best voice recognition offline, install the offline English speech pack in your phone settings. Say "help" any time to hear this again.',
    ];
    for (final s in steps) {
      await speaker.speak(s, mode: SpeakMode.queue);
    }
  }

  // ---- mode switching ------------------------------------------------------

  Future<void> _enter(AssistModule m, {bool announce = true}) async {
    m.active = true;
    await m.onEnter();
    if (announce) {
      final giveHint = Settings.instance.shouldGiveHint(m.id);
      unawaited(Settings.instance.save());
      unawaited(speaker.speak(giveHint ? '${m.title}. ${m.hint}' : m.title));
    }
    await _syncCamera();
    notifyListeners();
  }

  Future<void> _syncCamera() async {
    final cam = CameraService.instance;
    if (calls.takesOverScreen) {
      await cam.setHandler(null);
      return;
    }
    if (active.usesCamera && active.wantsFrames) {
      final m = active;
      await cam.setHandler((f) async {
        if (m.active) await m.onFrame(f);
      });
    } else {
      await cam.setHandler(null);
    }
  }

  Future<void> switchTo(int i) async {
    if (i == index && active.active) return;
    final old = active;
    old.active = false;
    await old.onExit();
    index = (i % modules.length + modules.length) % modules.length;
    Settings.instance.lastModeId = active.id;
    Cues.instance.tick();
    await _enter(active);
  }

  Future<void> next() => switchTo(index + 1);
  Future<void> previous() => switchTo(index - 1);

  @override
  Future<void> openMode(String id, {Command? command}) async {
    final i = modules.indexWhere((m) => m.id == id);
    if (i < 0) return;
    if (i != index) {
      final old = active;
      old.active = false;
      await old.onExit();
      index = i;
      Settings.instance.lastModeId = id;
      // Only the title: the user asked for something specific.
      await _enter(active, announce: false);
      if (command == null) {
        await speaker.speak('${active.title}. ${active.hint}');
      } else {
        await speaker.speak(active.title);
      }
    }
    if (command != null) await active.handle(command);
  }

  // ---- gestures ------------------------------------------------------------

  Future<void> onTap() async {
    if (calls.takesOverScreen) return calls.onTakeoverTap();
    final sos = module('emergency') as EmergencyModule;
    if (sos.countingDown) return sos.cancelSos();
    if (listeningForCommand) {
      await SpeechInput.instance.cancel();
      return;
    }
    await speaker.stop();
    await active.onTap();
    notifyListeners();
  }

  Future<void> onDoubleTap() async {
    if (calls.takesOverScreen) return calls.onTakeoverTap();
    await speaker.stop();
    await active.onDoubleTap();
    notifyListeners();
  }

  Future<void> onSwipeUp() => speaker.repeat();
  Future<void> onSwipeDown() async {
    await speaker.stop();
    Cues.instance.tick();
  }

  // ---- voice ---------------------------------------------------------------

  @override
  Future<String?> ask(String prompt, {Duration timeout = const Duration(seconds: 8)}) async {
    await speaker.speak(prompt);
    await Cues.instance.listeningCue();
    listeningForCommand = true;
    notifyListeners();
    try {
      return await SpeechInput.instance.listenOnce(timeout: timeout);
    } finally {
      listeningForCommand = false;
      notifyListeners();
    }
  }

  @override
  Future<bool> confirm(String prompt) async {
    final a = await ask('$prompt Say yes or no.', timeout: const Duration(seconds: 6));
    return isAffirmative(a);
  }

  /// Long press: listen for a command and run it.
  Future<void> voiceCommand() async {
    if (calls.takesOverScreen || listeningForCommand) return;
    await speaker.stop();
    await Cues.instance.listeningCue();
    listeningForCommand = true;
    notifyListeners();
    String? heard;
    try {
      heard = await SpeechInput.instance.listenOnce(timeout: const Duration(seconds: 7));
    } finally {
      listeningForCommand = false;
      notifyListeners();
    }
    if (heard == null) {
      Cues.instance.error();
      final hint = SpeechInput.instance.available
          ? 'I did not hear anything.'
          : 'Speech recognition is not available. Please install the offline English speech pack in your phone settings.';
      return speaker.speak(hint);
    }
    await runCommand(parseCommand(heard));
  }

  Future<void> runCommand(Command c) async {
    caption = '“${c.raw}”';
    notifyListeners();
    // Safety first: emergency works from anywhere.
    if (c.intent == VoiceIntent.emergency) {
      return openMode('emergency', command: c);
    }
    // App settings phrases that would otherwise look like other intents
    // ("clock directions" is not the time, "flashlight" is not light level).
    final raw = normalizeUtterance(c.raw);
    if (raw.contains('tutorial')) return tutorial();
    if (raw.contains('permission')) {
      await speaker.speak('Opening app settings. Choose permissions and allow them.');
      await openAppSettings();
      return;
    }
    if (raw.contains('flashlight') || raw.contains('torch')) {
      final on = !CameraService.instance.torchOn;
      await CameraService.instance.setTorch(on);
      return speaker.speak(on ? 'Flashlight on.' : 'Flashlight off.');
    }
    if (raw.contains('clock direction')) {
      Settings.instance.useClockDirections = !Settings.instance.useClockDirections;
      await Settings.instance.save();
      return speaker
          .speak(Settings.instance.useClockDirections ? 'Using clock directions.' : 'Using left, ahead and right.');
    }
    if (raw.contains('vibration') || raw.contains('haptic')) {
      Settings.instance.haptics = !raw.contains('off');
      Cues.instance.hapticsEnabled = Settings.instance.haptics;
      await Settings.instance.save();
      return speaker.speak(Settings.instance.haptics ? 'Vibration on.' : 'Vibration off.');
    }
    if (raw.contains('shake')) {
      Settings.instance.shakeForSos = !raw.contains('off');
      await Settings.instance.save();
      return speaker
          .speak(Settings.instance.shakeForSos ? 'Shake for emergency is on.' : 'Shake for emergency is off.');
    }
    // The active mode gets the first chance (e.g. "reset total" in currency).
    if (await active.handle(c)) return;
    switch (c.intent) {
      case VoiceIntent.time:
        final n = DateTime.now();
        final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
        return speaker.speak('It is $h:${n.minute.toString().padLeft(2, '0')} ${n.hour < 12 ? 'AM' : 'PM'}.');
      case VoiceIntent.date:
        final n = DateTime.now();
        const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
        const months = [
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December'
        ];
        return speaker.speak('Today is ${days[n.weekday - 1]}, ${n.day} ${months[n.month - 1]} ${n.year}.');
      case VoiceIntent.repeat:
        return speaker.repeat();
      case VoiceIntent.stop:
      case VoiceIntent.cancel:
      case VoiceIntent.no:
        return speaker.stop();
      case VoiceIntent.faster:
      case VoiceIntent.slower:
        final r = Settings.instance.speechRate + (c.intent == VoiceIntent.faster ? 0.1 : -0.1);
        Settings.instance.speechRate = math.max(0.2, math.min(0.9, r));
        await speaker.setRate(Settings.instance.speechRate);
        await Settings.instance.save();
        return speaker.speak(c.intent == VoiceIntent.faster ? 'Speaking faster.' : 'Speaking slower.');
      case VoiceIntent.brief:
      case VoiceIntent.verbose:
        Settings.instance.verbose = c.intent == VoiceIntent.verbose;
        await Settings.instance.save();
        return speaker.speak(Settings.instance.verbose ? 'I will give full hints.' : 'I will keep it short.');
      case VoiceIntent.help:
        return speaker.speak('${active.title}. ${active.help} Say "tutorial" to hear how to use the whole app. '
            'Modes are: ${modules.map((m) => m.title).join(', ')}.');
      case VoiceIntent.openMode:
        return openMode(c.arg!);
      case VoiceIntent.listSaved:
        return openMode('objects', command: c);
      default:
        break;
    }
    final home = intentHome[c.intent];
    if (home != null) return openMode(home, command: c);
    Cues.instance.error();
    await speaker.speak('Sorry, I did not understand "${c.raw}". Say "help" to hear what you can say.');
  }

  // ---- calls take over the screen ---------------------------------------------

  void _onCallStarted() {
    CameraService.instance.setHandler(null);
    notifyListeners();
  }

  void _onCallFinished() {
    _syncCamera();
    notifyListeners();
  }

  // ---- shake for SOS -----------------------------------------------------------

  void _startShakeDetection() {
    _shakeSub = userAccelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
      if (!Settings.instance.shakeForSos) return;
      final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      if (m < 25) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_shakeTimes.isNotEmpty && now - _shakeTimes.last < 250) return;
      _shakeTimes.add(now);
      _shakeTimes.removeWhere((t) => now - t > 1500);
      if (_shakeTimes.length >= 3) {
        _shakeTimes.clear();
        openMode('emergency', command: const Command(VoiceIntent.emergency, 'shake'));
      }
    });
  }

  // ---- lifecycle ---------------------------------------------------------------

  Future<void> onPaused() async {
    await CameraService.instance.pause();
  }

  Future<void> onResumed() async {
    if (!ready) return;
    await CameraService.instance.resume();
    await _syncCamera();
  }

  @override
  void dispose() {
    _shakeSub?.cancel();
    super.dispose();
  }
}
