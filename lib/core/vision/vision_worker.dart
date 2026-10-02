import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'detection.dart';
import 'embedding.dart';
import 'frame.dart';
import 'labels.dart';

/// Asset paths of the bundled on-device models.
class ModelAssets {
  static const coco = 'assets/models/coco_yolo11n.tflite';
  static const currency = 'assets/models/pkr_currency_yolo11n.tflite';
  static const imageEmbedder = 'assets/models/image_embedder.tflite';
  static const faceEmbedder = 'assets/models/face_embedder.tflite';
}

/// What to compute for one frame. Several tasks share one frame transfer.
class VisionRequest {
  final bool objects;
  final double objectConf;
  final bool currency;
  final double currencyConf;
  final List<NormRect> embedRegions;
  final List<NormRect> faceRegions;

  /// Optional in-plane roll per face (ML Kit headEulerAngleZ, degrees,
  /// counter-clockwise positive) used to straighten the crop.
  final List<double> faceRolls;

  const VisionRequest({
    this.objects = false,
    this.objectConf = 0.4,
    this.currency = false,
    this.currencyConf = 0.5,
    this.embedRegions = const [],
    this.faceRegions = const [],
    this.faceRolls = const [],
  });
}

class VisionResult {
  final List<Detection> objects;
  final List<Detection> currency;
  final List<Float32List> embeddings;
  final List<Float32List> faceEmbeddings;
  final int elapsedMs;

  const VisionResult({
    this.objects = const [],
    this.currency = const [],
    this.embeddings = const [],
    this.faceEmbeddings = const [],
    this.elapsedMs = 0,
  });
}

/// Runs all TensorFlow Lite models on a long-lived background isolate so
/// the UI and speech never stutter. Everything is on-device.
class VisionWorker {
  VisionWorker._();
  static final VisionWorker instance = VisionWorker._();

  SendPort? _send;
  Isolate? _isolate;
  Completer<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Map>> _pending = {};

  bool _busy = false;

  /// True while a request is in flight; live modes skip frames meanwhile.
  bool get busy => _busy;

  Future<void> start() async {
    if (_send != null) return;
    if (_starting != null) return _starting!.future;
    _starting = Completer<void>();
    try {
      final models = <String, TransferableTypedData>{};
      for (final a in [
        ModelAssets.coco,
        ModelAssets.currency,
        ModelAssets.imageEmbedder,
        ModelAssets.faceEmbedder,
      ]) {
        final data = await rootBundle.load(a);
        models[a] = TransferableTypedData.fromList([data.buffer.asUint8List()]);
      }
      final ready = ReceivePort();
      _isolate = await Isolate.spawn(_workerMain, [ready.sendPort, models]);
      final completer = Completer<SendPort>();
      ready.listen((msg) {
        if (msg is SendPort) {
          completer.complete(msg);
        } else if (msg is Map) {
          final c = _pending.remove(msg['id'] as int);
          c?.complete(msg);
        }
      });
      _send = await completer.future;
      _starting!.complete();
    } catch (e) {
      _starting!.completeError(e);
      _starting = null;
      rethrow;
    }
  }

  Future<VisionResult> run(NV21Frame frame, VisionRequest req) async {
    await start();
    final id = _nextId++;
    final c = Completer<Map>();
    _pending[id] = c;
    _busy = true;
    _send!.send({
      'id': id,
      'frame': frame.toMessage(),
      'objects': req.objects,
      'objectConf': req.objectConf,
      'currency': req.currency,
      'currencyConf': req.currencyConf,
      'embed': req.embedRegions.map((r) => r.toList()).toList(),
      'faces': [
        for (int i = 0; i < req.faceRegions.length; i++)
          [...req.faceRegions[i].toList(), i < req.faceRolls.length ? req.faceRolls[i] : 0.0],
      ],
    });
    try {
      final m = await c.future;
      if (m['error'] != null) throw StateError(m['error'] as String);
      return VisionResult(
        objects: (m['objects'] as List).map((e) => Detection.fromMessage(e as Map)).toList(),
        currency: (m['currency'] as List).map((e) => Detection.fromMessage(e as Map)).toList(),
        embeddings: (m['embed'] as List).cast<Float32List>(),
        faceEmbeddings: (m['faces'] as List).cast<Float32List>(),
        elapsedMs: m['ms'] as int,
      );
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
  }
}

// ---------------------------------------------------------------------------
// Isolate side
// ---------------------------------------------------------------------------

class _Model {
  final Interpreter itp;
  final int inputSize;
  final List<int> outShape;
  late final Float32List input;

  _Model(this.itp)
      : inputSize = itp.getInputTensor(0).shape[1],
        outShape = itp.getOutputTensor(0).shape {
    input = Float32List(inputSize * inputSize * 3);
  }

  Float32List invoke() {
    itp.getInputTensor(0).data = input.buffer.asUint8List();
    itp.invoke();
    final raw = itp.getOutputTensor(0).data;
    return Float32List.fromList(Float32List.sublistView(Uint8List.fromList(raw)));
  }
}

void _workerMain(List args) {
  final SendPort out = args[0] as SendPort;
  final models = (args[1] as Map).cast<String, TransferableTypedData>();
  final inbox = ReceivePort();
  out.send(inbox.sendPort);

  final bytes = <String, Uint8List>{};
  final loaded = <String, _Model>{};

  _Model model(String asset) {
    return loaded.putIfAbsent(asset, () {
      final b = bytes[asset] ??= models[asset]!.materialize().asUint8List();
      final opts = InterpreterOptions()..threads = 2;
      final itp = Interpreter.fromBuffer(b, options: opts)..allocateTensors();
      return _Model(itp);
    });
  }

  List<Detection> runYolo(String asset, NV21Frame f, List<String> labels, double conf, {bool agnostic = false}) {
    final m = model(asset);
    final lb = frameToTensor(f, m.input, m.inputSize);
    final o = m.invoke();
    final nc = m.outShape[1] - 4;
    final n = m.outShape[2];
    return decodeYolo(o, nc, n, labels, lb, confThreshold: conf, classAgnosticNms: agnostic);
  }

  Float32List embed(String asset, NV21Frame f, NormRect r,
      {required double mul, required double add, double roll = 0}) {
    final m = model(asset);
    frameToTensor(f, m.input, m.inputSize, region: r, letterbox: false, mul: mul, add: add, ccwDegrees: roll);
    return l2Normalize(m.invoke());
  }

  inbox.listen((msg) {
    final req = msg as Map;
    final id = req['id'] as int;
    final sw = Stopwatch()..start();
    try {
      final f = NV21Frame.fromMessage(req['frame'] as Map);
      final objects = req['objects'] == true
          ? runYolo(ModelAssets.coco, f, cocoLabels, (req['objectConf'] as num).toDouble())
          : const <Detection>[];
      final currency = req['currency'] == true
          ? runYolo(ModelAssets.currency, f, pkrLabels, (req['currencyConf'] as num).toDouble(), agnostic: true)
          : const <Detection>[];
      final embeds = (req['embed'] as List)
          .map((r) => embed(ModelAssets.imageEmbedder, f, NormRect.fromList(r as List), mul: 1 / 255.0, add: 0))
          .toList();
      final faces = (req['faces'] as List)
          .map((r) => embed(ModelAssets.faceEmbedder, f, NormRect.fromList(r as List),
              mul: 1 / 127.5, add: -1, roll: (r[4] as num).toDouble()))
          .toList();
      out.send({
        'id': id,
        'objects': objects.map((d) => d.toMessage()).toList(),
        'currency': currency.map((d) => d.toMessage()).toList(),
        'embed': embeds,
        'faces': faces,
        'ms': sw.elapsedMilliseconds,
      });
    } catch (e) {
      out.send({'id': id, 'error': e.toString()});
    }
  });
}
