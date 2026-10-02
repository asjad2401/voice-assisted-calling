import 'dart:async';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

import '../vision/frame.dart';

typedef FrameHandler = Future<void> Function(NV21Frame frame);

/// Owns the back camera. Streams NV21 frames to exactly one handler (the
/// active mode), dropping frames while the handler is still busy so the
/// app always works on the freshest image.
class CameraService extends ChangeNotifier {
  CameraService._();
  static final CameraService instance = CameraService._();

  CameraController? _controller;
  CameraDescription? _camera;
  FrameHandler? _handler;
  bool _handling = false;
  bool _streaming = false;
  bool _initializing = false;
  NV21Frame? latestFrame;
  bool torchOn = false;
  String? lastError;

  CameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized ?? false;

  /// Clockwise rotation that makes sensor frames upright in portrait.
  int get rotation => _camera?.sensorOrientation ?? 90;

  Future<bool> ensureInitialized() async {
    if (isReady) return true;
    if (_initializing) {
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return isReady;
    }
    _initializing = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        lastError = 'No camera found';
        return false;
      }
      _camera = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await c.initialize();
      try {
        await c.setFlashMode(FlashMode.off);
        await c.setFocusMode(FocusMode.auto);
      } catch (_) {}
      _controller = c;
      lastError = null;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    } finally {
      _initializing = false;
    }
  }

  /// Routes frames to [handler]; pass null to stop processing (preview
  /// keeps running).
  Future<void> setHandler(FrameHandler? handler) async {
    _handler = handler;
    if (handler != null) {
      await _startStream();
    } else {
      await _stopStream();
    }
  }

  Future<void> _startStream() async {
    if (_streaming || !await ensureInitialized()) return;
    _streaming = true;
    try {
      await _controller!.startImageStream(_onImage);
    } catch (e) {
      _streaming = false;
      lastError = e.toString();
    }
  }

  Future<void> _stopStream() async {
    if (!_streaming) return;
    _streaming = false;
    try {
      await _controller?.stopImageStream();
    } catch (_) {}
  }

  void _onImage(CameraImage img) {
    if (img.planes.isEmpty) return;
    final frame = NV21Frame(
      bytes: img.planes.first.bytes,
      width: img.width,
      height: img.height,
      rowStride: img.planes.first.bytesPerRow,
      rotation: rotation,
    );
    latestFrame = frame;
    final h = _handler;
    if (h == null || _handling) return;
    _handling = true;
    h(frame).catchError((Object e) {
      debugPrint('frame handler error: $e');
    }).whenComplete(() => _handling = false);
  }

  /// Waits for a fresh frame (useful right after the stream starts).
  Future<NV21Frame?> nextFrame({Duration timeout = const Duration(seconds: 2)}) async {
    if (!_streaming) {
      // Stream with a no-op handler just to grab frames.
      _handler ??= (_) async {};
      await _startStream();
    }
    final before = latestFrame;
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (latestFrame != null && !identical(latestFrame, before)) return latestFrame;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    return latestFrame;
  }

  /// Takes a full-resolution still photo (used for reading text). The image
  /// stream is paused during capture, as required on many devices.
  Future<String?> takePicture({bool flashIfDark = false}) async {
    if (!await ensureInitialized()) return null;
    final wasStreaming = _streaming;
    await _stopStream();
    try {
      if (flashIfDark) await _controller!.setFlashMode(FlashMode.auto);
      final file = await _controller!.takePicture();
      return file.path;
    } catch (e) {
      lastError = e.toString();
      return null;
    } finally {
      try {
        await _controller!.setFlashMode(torchOn ? FlashMode.torch : FlashMode.off);
      } catch (_) {}
      if (wasStreaming && _handler != null) await _startStream();
    }
  }

  Future<void> setTorch(bool on) async {
    if (!await ensureInitialized()) return;
    try {
      await _controller!.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      torchOn = on;
    } catch (_) {}
  }

  /// ML Kit input for a streamed frame.
  InputImage toInputImage(NV21Frame f) => InputImage.fromBytes(
        bytes: f.bytes,
        metadata: InputImageMetadata(
          size: Size(f.width.toDouble(), f.height.toDouble()),
          rotation: InputImageRotationValue.fromRawValue(f.rotation) ?? InputImageRotation.rotation90deg,
          format: InputImageFormat.nv21,
          bytesPerRow: f.rowStride,
        ),
      );

  Future<void> pause() async {
    await _stopStream();
    final c = _controller;
    _controller = null;
    torchOn = false;
    notifyListeners();
    await c?.dispose();
  }

  /// Re-opens the camera after [pause] and restores the active handler.
  Future<void> resume() async {
    if (await ensureInitialized() && _handler != null) await _startStream();
  }
}
