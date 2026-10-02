import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/camera/camera_service.dart';
import '../core/commands.dart';
import '../core/nav/motion.dart';
import '../core/nav/route.dart';
import '../core/speech/speaker.dart';
import '../core/storage/store.dart';
import '../core/vision/detection.dart';
import '../core/vision/embedding.dart';
import '../core/vision/frame.dart';
import '../core/vision/vision_worker.dart';
import 'module.dart';

enum PlacesState { idle, recording, guiding }

/// Indoor landmark navigation without any infrastructure:
///  * Save landmarks ("kitchen door") from a few camera views; later the
///    app recognizes where you are by looking around.
///  * Record a route by walking it once: steps are counted with the
///    accelerometer and turns measured with the compass.
///  * Get guided along saved routes (chained across landmarks) with step
///    countdowns and turn instructions.
class PlacesModule extends AssistModule {
  @override
  String get id => 'places';
  @override
  String get title => 'Places';
  @override
  IconData get icon => Icons.place;
  @override
  Color get color => const Color(0xFF1F3A5C);
  @override
  String get hint =>
      'Tap to hear where you are. Double tap to save this spot as a landmark. Say "record route to", or "take me to", followed by a place name.';
  @override
  String get help =>
      'Places helps you find your way indoors, with no internet or beacons. First save landmarks: stand at a spot such as the kitchen door, double tap, say a name, and slowly turn the phone left and right. '
      'Then record a route: stand at one landmark and say "record route to kitchen", walk there normally holding the phone upright in front of you, and tap when you arrive. The way back is saved automatically. '
      'Later say "take me to kitchen". I will count down your steps, tell you when to turn, and beep when you face the right way. Tap to hear where you are. '
      'Step counts and compass directions are approximate, so use your cane and familiar cues too.';
  @override
  String get tapLabel => state == PlacesState.recording
      ? 'Finish recording'
      : state == PlacesState.guiding
          ? 'Repeat instruction'
          : 'Where am I';
  @override
  String get doubleTapLabel => state == PlacesState.idle ? 'Save this place' : 'Stop';

  static const double landmarkThreshold = 0.7;

  PlacesState state = PlacesState.idle;
  List<GalleryEntry> _landmarks = [];
  DateTime _lastLook = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastAnnouncedPlace;

  // Sensors.
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  final StepDetector _steps = StepDetector();
  final HeadingFilter _heading = HeadingFilter();
  List<double> _gravity = [0, 9.8, 0];
  List<double>? _mag;

  // Recording / guiding.
  RouteRecorder? _recorder;
  String? _recordFrom, _recordTo;
  RouteGuide? _guide;
  String _lastInstruction = '';
  DateTime _lastAlignBeep = DateTime.fromMillisecondsSinceEpoch(0);

  double? get heading => _heading.value;

  @override
  bool get wantsFrames => true;

  @override
  Future<void> onEnter() async {
    _landmarks = await store.gallery(GalleryKind.landmark);
    _updateStatus();
  }

  void _updateStatus() {
    switch (state) {
      case PlacesState.idle:
        status = host.currentPlace != null
            ? 'Near ${host.currentPlace}'
            : _landmarks.isEmpty
                ? 'No landmarks yet. Double tap to save one.'
                : '${_landmarks.length} landmarks saved';
        break;
      case PlacesState.recording:
        status = 'Recording route to $_recordTo: ${_recorder?.totalSteps ?? 0} steps';
        break;
      case PlacesState.guiding:
        status = _lastInstruction;
        break;
    }
  }

  // ---- landmark recognition ------------------------------------------------

  List<NormRect> _viewRegions(NV21Frame f) => [
        NormRect.full.squareIn(f.uprightWidth, f.uprightHeight),
        NormRect.center(0.6, aspect: f.uprightWidth / f.uprightHeight),
      ];

  Future<GalleryMatch?> recognizePlace(NV21Frame f) async {
    if (_landmarks.isEmpty) return null;
    final r = await VisionWorker.instance.run(f, VisionRequest(embedRegions: _viewRegions(f)));
    GalleryMatch? best;
    for (final e in r.embeddings) {
      final m = bestGalleryMatch(e, _landmarks, threshold: landmarkThreshold, minMargin: 0.02);
      if (m != null && (best == null || m.score > best.score)) best = m;
    }
    return best;
  }

  @override
  Future<void> onFrame(NV21Frame frame) async {
    final now = DateTime.now();
    if (now.difference(_lastLook).inMilliseconds < 1200 || _landmarks.isEmpty) return;
    _lastLook = now;
    final m = await recognizePlace(frame);
    if (m == null) return;
    host.currentPlace = m.entry.name;
    if (m.entry.name != _lastAnnouncedPlace && state != PlacesState.recording) {
      _lastAnnouncedPlace = m.entry.name;
      cues.tick();
      await say('Near ${m.entry.name}.', mode: SpeakMode.ifIdle);
    }
    if (state == PlacesState.idle) _updateStatus();
  }

  Future<void> whereAmI() async {
    final f = await CameraService.instance.nextFrame();
    if (f == null) return say('The camera is not ready.');
    if (_landmarks.isEmpty) return say('No landmarks saved yet. Double tap to save this spot.');
    final m = await recognizePlace(f);
    if (m != null) {
      host.currentPlace = m.entry.name;
      _lastAnnouncedPlace = m.entry.name;
      return say('You seem to be near ${m.entry.name}.');
    }
    final last = host.currentPlace;
    await say(
        'I do not recognize this spot. Turn slowly so I can look around.${last != null ? ' Earlier you were near $last.' : ''}');
  }

  Future<void> saveLandmark(String? name) async {
    name ??= await host.ask('What should I call this place? For example, kitchen door.');
    if (name == null || name.trim().isEmpty) return say('Nothing was saved.');
    name = name.trim().toLowerCase().replaceFirst(RegExp(r'^(the|my) '), '');
    await say('Hold the phone upright and slowly turn a little left and right. Capturing.');
    final samples = <Float32List>[];
    for (int i = 0; i < 6; i++) {
      await Future.delayed(const Duration(milliseconds: 700));
      final f = await CameraService.instance.nextFrame();
      if (f == null) continue;
      final r = await VisionWorker.instance.run(f, VisionRequest(embedRegions: _viewRegions(f)));
      samples.addAll(r.embeddings);
      cues.beep(frequency: 900, durationMs: 50);
    }
    if (samples.isEmpty) return say('I could not capture this place.');
    final existing = _landmarks.where((l) => l.name == name).toList();
    if (existing.isNotEmpty) {
      await store.addSamples(existing.first.id, samples);
    } else {
      await store.addGalleryEntry(GalleryKind.landmark, name, samples, extra: {'heading': heading});
    }
    _landmarks = await store.gallery(GalleryKind.landmark);
    host.currentPlace = name;
    _lastAnnouncedPlace = name;
    await log('place', 'Saved landmark $name', subject: name);
    cues.confirm();
    await say(
        'Saved $name. To connect it to another place, stand here and say "record route to", followed by the other place.');
    _updateStatus();
  }

  // ---- sensors ---------------------------------------------------------------

  void _startSensors() {
    _accSub ??= accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      _gravity = [
        _gravity[0] * 0.8 + e.x * 0.2,
        _gravity[1] * 0.8 + e.y * 0.2,
        _gravity[2] * 0.8 + e.z * 0.2,
      ];
      if (_steps.add(e.x, e.y, e.z, DateTime.now().millisecondsSinceEpoch)) _onStep();
    });
    _magSub ??= magnetometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      _mag = [e.x, e.y, e.z];
      final h = headingDegrees(_gravity[0], _gravity[1], _gravity[2], e.x, e.y, e.z);
      if (h != null) _heading.add(h);
      _onHeading();
    });
  }

  void _stopSensors() {
    _accSub?.cancel();
    _magSub?.cancel();
    _accSub = null;
    _magSub = null;
  }

  bool get hasCompass => _mag != null;

  void _onStep() {
    switch (state) {
      case PlacesState.recording:
        final h = heading;
        if (h == null) return;
        if (_recorder!.addStep(h)) cues.tick();
        _updateStatus();
        break;
      case PlacesState.guiding:
        final e = _guide!.onStep(heading);
        if (e != null) _instruct(e);
        break;
      case PlacesState.idle:
        break;
    }
  }

  void _onHeading() {
    if (state != PlacesState.guiding || _guide == null) return;
    final h = heading;
    if (h == null) return;
    final e = _guide!.onHeading(h);
    if (e != null) {
      _instruct(e);
      return;
    }
    // While waiting to turn, beep faster as the user faces the right way.
    final err = angleDiff(_guide!.targetHeading, h).abs();
    final now = DateTime.now();
    if (err < 90 && now.difference(_lastAlignBeep).inMilliseconds > 250 + err * 10) {
      _lastAlignBeep = now;
      if (_guide!.stepsRemainingInSegment == _guide!.route.segments[_guide!.segmentIndex].steps) {
        cues.beep(frequency: (1100 - err * 6).round(), durationMs: 40, volume: 0.5);
      }
    }
  }

  void _instruct(GuideEvent e) {
    _lastInstruction = e.message;
    status = e.message;
    if (e.kind == GuideEventKind.turn || e.kind == GuideEventKind.arrived) cues.confirm();
    say(e.message, mode: e.kind == GuideEventKind.progress ? SpeakMode.ifIdle : SpeakMode.interrupt);
    if (e.kind == GuideEventKind.arrived) {
      log('navigation', 'Arrived at ${_guide!.route.to}', subject: _guide!.route.to);
      host.currentPlace = _guide!.route.to;
      _endNavigation();
    }
  }

  // ---- routes ------------------------------------------------------------------

  Future<void> startRecording(String? to) async {
    if (state != PlacesState.idle) {
      return say('Already ${state == PlacesState.recording ? 'recording' : 'guiding'}. Double tap to stop first.');
    }
    var from = host.currentPlace;
    final f = await CameraService.instance.nextFrame();
    if (f != null) {
      final m = await recognizePlace(f);
      if (m != null) from = m.entry.name;
    }
    if (from == null) {
      from = await host.ask('Where are you starting from?');
      if (from == null) return say('I need a starting place.');
    }
    to ??= await host.ask('Where are you walking to?');
    if (to == null) return say('I need a destination.');
    _recordFrom = from.toLowerCase();
    _recordTo = to.toLowerCase().replaceFirst(RegExp(r'^(the|my) '), '');
    _recorder = RouteRecorder();
    _steps.reset();
    _startSensors();
    state = PlacesState.recording;
    cues.keepScreenOn(true);
    _updateStatus();
    await say(
        'Recording from $_recordFrom to $_recordTo. Hold the phone upright and walk normally. Tap when you arrive.');
  }

  Future<void> finishRecording() async {
    final segs = _recorder?.finish() ?? const <RouteSegment>[];
    state = PlacesState.idle;
    cues.keepScreenOn(false);
    if (_guide == null) _stopSensors();
    if (segs.isEmpty || segs.fold(0, (a, s) => a + s.steps) < 3) {
      await say('I counted too few steps, so the route was not saved.');
      _updateStatus();
      return;
    }
    final route = SavedRoute(from: _recordFrom!, to: _recordTo!, segments: segs);
    await store.saveRoute(route);
    host.currentPlace = _recordTo;
    await log('navigation', 'Recorded route from ${route.from} to ${route.to}: ${route.describe()}');
    cues.confirm();
    await say('Saved route from ${route.from} to ${route.to}: ${route.describe()}. '
        '${_landmarks.any((l) => l.name == _recordTo) ? '' : 'Double tap to save this spot as a landmark too.'}');
    _updateStatus();
  }

  Future<void> navigateTo(String spoken) async {
    if (state != PlacesState.idle) await _endNavigation(speak: false);
    final routes = await store.routes();
    if (routes.isEmpty) {
      return say(
          'No routes are recorded yet. Stand at a place and say "record route to", followed by where you are going.');
    }
    final places = {
      for (final r in routes) ...[r.from, r.to]
    };
    final dest = matchName(spoken, places);
    if (dest == null) {
      return say('I do not know a place called $spoken. Known places are ${joinSpoken(places.toList())}.');
    }
    var from = host.currentPlace;
    final f = await CameraService.instance.nextFrame();
    if (f != null) {
      final m = await recognizePlace(f);
      if (m != null) from = m.entry.name;
    }
    from ??= await host.ask('Where are you now?');
    final start = from == null ? null : matchName(from, places);
    if (start == null) return say('I need to know where you are starting. Try standing at a saved landmark.');
    final route = findRoute(routes, start, dest);
    if (route == null) return say('I do not have a route from $start to $dest yet.');
    _guide = RouteGuide(route);
    _steps.reset();
    _startSensors();
    state = PlacesState.guiding;
    cues.keepScreenOn(true);
    await Future.delayed(const Duration(milliseconds: 300)); // let the compass settle
    final e = _guide!.start(heading);
    _lastInstruction = e.message;
    status = e.message;
    await log('navigation', 'Started guidance from $start to $dest', subject: dest);
    await say(e.message);
  }

  Future<void> _endNavigation({bool speak = true}) async {
    final wasGuiding = state == PlacesState.guiding;
    state = PlacesState.idle;
    _guide = null;
    _recorder = null;
    _stopSensors();
    cues.keepScreenOn(false);
    if (speak && wasGuiding) await say('Navigation stopped.');
    _updateStatus();
  }

  // ---- gestures and commands -------------------------------------------------

  @override
  Future<void> onTap() async {
    switch (state) {
      case PlacesState.recording:
        return finishRecording();
      case PlacesState.guiding:
        return say(_lastInstruction.isEmpty ? 'Keep walking.' : _lastInstruction);
      case PlacesState.idle:
        return whereAmI();
    }
  }

  @override
  Future<void> onDoubleTap() async {
    switch (state) {
      case PlacesState.recording:
        state = PlacesState.idle;
        _recorder = null;
        _stopSensors();
        cues.keepScreenOn(false);
        _updateStatus();
        return say('Recording cancelled.');
      case PlacesState.guiding:
        return _endNavigation();
      case PlacesState.idle:
        return saveLandmark(null);
    }
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.whereAmI:
        await whereAmI();
        return true;
      case VoiceIntent.saveLandmark:
        await saveLandmark(c.arg);
        return true;
      case VoiceIntent.recordRoute:
        await startRecording(c.arg);
        return true;
      case VoiceIntent.navigateTo:
        await navigateTo(c.arg ?? '');
        return true;
      case VoiceIntent.stopNavigation:
        if (state == PlacesState.recording) {
          await finishRecording();
        } else {
          await _endNavigation();
        }
        return true;
      case VoiceIntent.listSaved:
        final routes = await store.routes();
        final places = {
          for (final l in _landmarks) l.name,
          for (final r in routes) ...[r.from, r.to]
        };
        await say(places.isEmpty
            ? 'No places saved yet.'
            : 'Known places: ${joinSpoken(places.toList())}. ${routes.length} routes recorded.');
        return true;
      default:
        return false;
    }
  }

  /// Navigation keeps running when the user switches to another mode, so
  /// obstacle alerts can be used during guidance.
  bool get isBusy => state != PlacesState.idle;
}
