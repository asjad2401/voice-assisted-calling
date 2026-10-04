import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../core/camera/camera_service.dart';
import '../modules/calls/call_controller.dart';
import '../modules/module.dart';
import 'app_controller.dart';

/// The single full-screen surface. Gestures anywhere:
///   swipe left/right  – change mode
///   tap / double tap  – the mode's two main actions
///   long press        – voice command
///   swipe up / down   – repeat / stop speech
/// With TalkBack on, large labelled buttons are shown instead, since the
/// screen reader consumes raw gestures.
class HomeScreen extends StatefulWidget {
  final AppController controller;
  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppController get c => widget.controller;
  AssistModule? _listening;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_onChange);
    CallController.instance.addListener(_onChange);
    CameraService.instance.addListener(_onChange);
    c.start();
  }

  void _onChange() {
    if (_listening != c.active) {
      _listening?.removeListener(_onChange);
      _listening = c.active..addListener(_onChange);
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) c.onPaused();
    if (state == AppLifecycleState.resumed) c.onResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_onChange);
    CallController.instance.removeListener(_onChange);
    CameraService.instance.removeListener(_onChange);
    _listening?.removeListener(_onChange);
    super.dispose();
  }

  void _onPanEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < 300) return;
    if (v.dx.abs() > v.dy.abs()) {
      v.dx < 0 ? c.next() : c.previous();
    } else {
      v.dy < 0 ? c.onSwipeUp() : c.onSwipeDown();
    }
  }

  @override
  Widget build(BuildContext context) {
    final calls = CallController.instance;
    if (calls.takesOverScreen) return _CallOverlay(calls: calls);
    final m = c.active;
    final a11y = MediaQuery.of(context).accessibleNavigation;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: c.onTap,
        onDoubleTap: c.onDoubleTap,
        onLongPress: c.voiceCommand,
        onPanEnd: _onPanEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (m.usesCamera) const _Preview(),
            Container(color: m.color.withValues(alpha: m.usesCamera ? 0.55 : 1)),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ModeHeader(controller: c),
                    const SizedBox(height: 24),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: SingleChildScrollView(
                          child: Text(
                            m.status,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 34, height: 1.25, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    if (c.caption.isNotEmpty)
                      ExcludeSemantics(
                        child: Container(
                          margin: const EdgeInsets.only(top: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
                          child: Text(c.caption,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.yellowAccent, fontSize: 20)),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (a11y) _AccessibleControls(controller: c) else _GestureHints(listening: c.listeningForCommand),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview();

  // Listens to the camera itself: as a const child, this widget is skipped
  // when the parent rebuilds, so it would otherwise stay black if it was
  // first built before the camera finished initialising.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CameraService.instance,
      builder: (context, _) => _buildPreview(),
    );
  }

  Widget _buildPreview() {
    final ctl = CameraService.instance.controller;
    if (ctl == null || !ctl.value.isInitialized) return const ColoredBox(color: Colors.black);
    return ExcludeSemantics(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ctl.value.previewSize?.height ?? 720,
          height: ctl.value.previewSize?.width ?? 1280,
          child: CameraPreview(ctl),
        ),
      ),
    );
  }
}

class _ModeHeader extends StatelessWidget {
  final AppController controller;
  const _ModeHeader({required this.controller});

  @override
  Widget build(BuildContext context) {
    final m = controller.active;
    return Semantics(
      header: true,
      label: '${m.title} mode, ${controller.index + 1} of ${controller.modules.length}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(m.icon, color: Colors.white, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Text(m.title,
                    style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 10),
            Row(
              children: [
                for (int i = 0; i < controller.modules.length; i++)
                  Expanded(
                    child: Container(
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: i == controller.index ? Colors.white : Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureHints extends StatelessWidget {
  final bool listening;
  const _GestureHints({required this.listening});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: listening ? Colors.redAccent : Colors.black54,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          listening ? 'Listening…' : 'Tap · Double tap · Hold to speak · Swipe ◀ ▶ modes',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// Large buttons used when a screen reader is active.
class _AccessibleControls extends StatelessWidget {
  final AppController controller;
  const _AccessibleControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    final m = controller.active;
    Widget btn(String label, IconData icon, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: SizedBox(
              height: 84,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                onPressed: onTap,
                child: Semantics(
                  label: label,
                  excludeSemantics: true,
                  child: Icon(icon, size: 36),
                ),
              ),
            ),
          ),
        );
    return Column(
      children: [
        Row(children: [
          btn(m.tapLabel, Icons.touch_app, controller.onTap),
          btn(m.doubleTapLabel, Icons.ads_click, controller.onDoubleTap),
        ]),
        Row(children: [
          btn('Previous mode', Icons.chevron_left, () {
            controller.previous();
            SemanticsService.sendAnnouncement(View.of(context), 'Previous mode', TextDirection.ltr);
          }),
          btn('Voice command', Icons.mic, controller.voiceCommand),
          btn('Repeat', Icons.replay, controller.onSwipeUp),
          btn('Next mode', Icons.chevron_right, controller.next),
        ]),
      ],
    );
  }
}

class _CallOverlay extends StatelessWidget {
  final CallController calls;
  const _CallOverlay({required this.calls});

  @override
  Widget build(BuildContext context) {
    final ringing = calls.state == CallState.incoming;
    final label = ringing
        ? 'Incoming call from ${calls.target}. Tap anywhere to answer.'
        : 'In call with ${calls.target}. Tap anywhere to hang up.';
    return Scaffold(
      backgroundColor: ringing ? const Color(0xFF065F46) : const Color(0xFF7F1D1D),
      body: Semantics(
        button: true,
        label: label,
        onTap: calls.onTakeoverTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: calls.onTakeoverTap,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(ringing ? Icons.ring_volume : Icons.call_end, size: 120, color: Colors.white),
                      const SizedBox(height: 32),
                      Text(ringing ? 'INCOMING CALL' : 'IN CALL',
                          style: const TextStyle(color: Colors.white70, fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      Text(calls.target,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 32),
                      Text(
                          ringing
                              ? 'Tap anywhere to answer\nor say "answer" / "ignore"'
                              : 'Speaker on · Tap anywhere to hang up',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 24)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
