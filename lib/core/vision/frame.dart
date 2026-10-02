import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// Axis-aligned rectangle in normalized (0..1) coordinates of the *upright*
/// image, i.e. the image as the user sees it with the phone held in portrait.
class NormRect {
  final double left, top, right, bottom;

  const NormRect(this.left, this.top, this.right, this.bottom);

  static const full = NormRect(0, 0, 1, 1);

  /// Square-ish centered crop covering [fraction] of the shorter side.
  factory NormRect.center(double fraction, {double aspect = 1.0}) {
    // aspect = upright width / upright height
    final h = fraction;
    final w = (fraction / aspect).clamp(0.0, 1.0);
    return NormRect(0.5 - w / 2, 0.5 - h / 2, 0.5 + w / 2, 0.5 + h / 2);
  }

  double get width => right - left;
  double get height => bottom - top;
  double get area => width * height;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  NormRect clamp() => NormRect(
        left.clamp(0.0, 1.0),
        top.clamp(0.0, 1.0),
        right.clamp(0.0, 1.0),
        bottom.clamp(0.0, 1.0),
      );

  /// Grows the rect by [factor] of its own size on every side.
  NormRect inflate(double factor) => NormRect(
        left - width * factor,
        top - height * factor,
        right + width * factor,
        bottom + height * factor,
      ).clamp();

  /// Makes the rect square in *pixel* space for an upright image of
  /// [imgW] x [imgH], keeping its center.
  NormRect squareIn(int imgW, int imgH) {
    final wPx = width * imgW, hPx = height * imgH;
    final side = wPx > hPx ? wPx : hPx;
    final hw = side / imgW / 2, hh = side / imgH / 2;
    return NormRect(centerX - hw, centerY - hh, centerX + hw, centerY + hh).clamp();
  }

  double iou(NormRect o) {
    final ix = (right < o.right ? right : o.right) - (left > o.left ? left : o.left);
    final iy = (bottom < o.bottom ? bottom : o.bottom) - (top > o.top ? top : o.top);
    if (ix <= 0 || iy <= 0) return 0;
    final inter = ix * iy;
    return inter / (area + o.area - inter);
  }

  List<double> toList() => [left, top, right, bottom];
  factory NormRect.fromList(List<dynamic> l) =>
      NormRect((l[0] as num).toDouble(), (l[1] as num).toDouble(), (l[2] as num).toDouble(), (l[3] as num).toDouble());

  @override
  String toString() =>
      'NormRect(${left.toStringAsFixed(2)}, ${top.toStringAsFixed(2)}, ${right.toStringAsFixed(2)}, ${bottom.toStringAsFixed(2)})';
}

/// A single camera frame in Android NV21 layout (Y plane followed by
/// interleaved V/U at quarter resolution), plus the clockwise rotation in
/// degrees needed to display it upright.
///
/// The frame is plain data so it can be sent to the vision isolate.
class NV21Frame {
  final Uint8List bytes;
  final int width; // sensor width
  final int height; // sensor height
  final int rowStride; // bytes per row of the Y plane
  final int rotation; // 0, 90, 180, 270

  const NV21Frame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotation,
    int? rowStride,
  }) : rowStride = rowStride ?? width;

  /// Width of the image as seen upright.
  int get uprightWidth => (rotation % 180 == 0) ? width : height;
  int get uprightHeight => (rotation % 180 == 0) ? height : width;

  Map<String, Object> toMessage() => {
        'b': TransferableTypedData.fromList([bytes]),
        'w': width,
        'h': height,
        's': rowStride,
        'r': rotation,
      };

  static NV21Frame fromMessage(Map msg) => NV21Frame(
        bytes: (msg['b'] as TransferableTypedData).materialize().asUint8List(),
        width: msg['w'] as int,
        height: msg['h'] as int,
        rowStride: msg['s'] as int,
        rotation: msg['r'] as int,
      );
}

/// Maps a pixel position in the upright image to the sensor image.
/// Returns the sensor (x, y) packed as x + y * 65536 for speed.
int uprightToSensor(int ux, int uy, int sensorW, int sensorH, int rotation) {
  int x, y;
  switch (rotation) {
    case 90:
      x = uy;
      y = sensorH - 1 - ux;
      break;
    case 180:
      x = sensorW - 1 - ux;
      y = sensorH - 1 - uy;
      break;
    case 270:
      x = sensorW - 1 - uy;
      y = ux;
      break;
    default:
      x = ux;
      y = uy;
  }
  return x + (y << 16);
}

/// Result of letterboxing a region into a square model input.
class LetterboxInfo {
  final double scale; // model px per upright source px
  final double padX, padY; // model px
  final double srcLeftPx, srcTopPx; // region origin in upright px
  final int uprightW, uprightH;

  const LetterboxInfo({
    required this.scale,
    required this.padX,
    required this.padY,
    required this.srcLeftPx,
    required this.srcTopPx,
    required this.uprightW,
    required this.uprightH,
  });

  /// Converts a box in model-input pixels back to normalized upright coords.
  NormRect toUpright(double x1, double y1, double x2, double y2) {
    double fx(double v) => (srcLeftPx + (v - padX) / scale) / uprightW;
    double fy(double v) => (srcTopPx + (v - padY) / scale) / uprightH;
    return NormRect(fx(x1), fy(y1), fx(x2), fy(y2)).clamp();
  }
}

/// Converts one YUV pixel to RGB components packed as 0xRRGGBB.
int _yuvToRgb(int y, int u, int v) {
  final c = y - 16 < 0 ? 0 : y - 16;
  final d = u - 128;
  final e = v - 128;
  int r = (298 * c + 409 * e + 128) >> 8;
  int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
  int b = (298 * c + 516 * d + 128) >> 8;
  r = r < 0 ? 0 : (r > 255 ? 255 : r);
  g = g < 0 ? 0 : (g > 255 ? 255 : g);
  b = b < 0 ? 0 : (b > 255 ? 255 : b);
  return (r << 16) | (g << 8) | b;
}

/// Reads the RGB color of the upright pixel (ux, uy).
int sampleRgb(NV21Frame f, int ux, int uy) {
  final p = uprightToSensor(ux, uy, f.width, f.height, f.rotation);
  final x = p & 0xFFFF, y = p >> 16;
  final yv = f.bytes[y * f.rowStride + x];
  final uvBase = f.rowStride * f.height;
  final uvIdx = uvBase + (y >> 1) * f.rowStride + (x & ~1);
  if (uvIdx + 1 >= f.bytes.length) return _yuvToRgb(yv, 128, 128);
  final v = f.bytes[uvIdx];
  final u = f.bytes[uvIdx + 1];
  return _yuvToRgb(yv, u, v);
}

/// Fills [out] (NHWC float32, size*size*3) with the [region] of the upright
/// frame, letterboxed to a square [size] with gray padding, in the value
/// range produced by `value * mul + add` where value is 0..255.
LetterboxInfo frameToTensor(
  NV21Frame f,
  Float32List out,
  int size, {
  NormRect region = NormRect.full,
  bool letterbox = true,
  double mul = 1 / 255.0,
  double add = 0,
  double ccwDegrees = 0,
}) {
  final uw = f.uprightWidth, uh = f.uprightHeight;
  if (ccwDegrees != 0 && !letterbox) {
    return _frameToTensorRotated(f, out, size, region, mul, add, ccwDegrees);
  }
  final srcL = region.left * uw, srcT = region.top * uh;
  final srcW = region.width * uw, srcH = region.height * uh;
  double scaleX, scaleY, padX = 0, padY = 0;
  if (letterbox) {
    final s = size / (srcW > srcH ? srcW : srcH);
    scaleX = scaleY = s;
    padX = (size - srcW * s) / 2;
    padY = (size - srcH * s) / 2;
  } else {
    scaleX = size / srcW;
    scaleY = size / srcH;
  }
  final padVal = 114 * mul + add;
  int o = 0;
  for (int my = 0; my < size; my++) {
    final sy = (my + 0.5 - padY) / scaleY;
    final inY = sy >= 0 && sy < srcH;
    final uy = (srcT + sy).floor().clamp(0, uh - 1);
    for (int mx = 0; mx < size; mx++) {
      final sx = (mx + 0.5 - padX) / scaleX;
      if (!inY || sx < 0 || sx >= srcW) {
        out[o++] = padVal;
        out[o++] = padVal;
        out[o++] = padVal;
        continue;
      }
      final ux = (srcL + sx).floor().clamp(0, uw - 1);
      final rgb = sampleRgb(f, ux, uy);
      out[o++] = ((rgb >> 16) & 0xFF) * mul + add;
      out[o++] = ((rgb >> 8) & 0xFF) * mul + add;
      out[o++] = (rgb & 0xFF) * mul + add;
    }
  }
  return LetterboxInfo(
    scale: scaleX,
    padX: padX,
    padY: padY,
    srcLeftPx: srcL,
    srcTopPx: srcT,
    uprightW: uw,
    uprightH: uh,
  );
}

/// Samples [region] while undoing a counter-clockwise (as seen on screen)
/// rotation of its content by [ccwDegrees] around the region center, e.g.
/// to straighten a tilted face before computing its embedding.
LetterboxInfo _frameToTensorRotated(
    NV21Frame f, Float32List out, int size, NormRect region, double mul, double add, double ccwDegrees) {
  final uw = f.uprightWidth, uh = f.uprightHeight;
  final cx = region.centerX * uw, cy = region.centerY * uh;
  final w = region.width * uw, h = region.height * uh;
  final rad = ccwDegrees * math.pi / 180;
  final cosA = math.cos(rad), sinA = math.sin(rad);
  int o = 0;
  for (int my = 0; my < size; my++) {
    final dy = ((my + 0.5) / size - 0.5) * h;
    for (int mx = 0; mx < size; mx++) {
      final dx = ((mx + 0.5) / size - 0.5) * w;
      final sx = cx + dx * cosA + dy * sinA;
      final sy = cy - dx * sinA + dy * cosA;
      if (sx < 0 || sy < 0 || sx >= uw || sy >= uh) {
        final pad = 114 * mul + add;
        out[o++] = pad;
        out[o++] = pad;
        out[o++] = pad;
        continue;
      }
      final rgb = sampleRgb(f, sx.floor(), sy.floor());
      out[o++] = ((rgb >> 16) & 0xFF) * mul + add;
      out[o++] = ((rgb >> 8) & 0xFF) * mul + add;
      out[o++] = (rgb & 0xFF) * mul + add;
    }
  }
  return LetterboxInfo(
      scale: size / w,
      padX: 0,
      padY: 0,
      srcLeftPx: region.left * uw,
      srcTopPx: region.top * uh,
      uprightW: uw,
      uprightH: uh);
}

/// Returns a grid of RGB samples (packed 0xRRGGBB) over [region], [n] x [n].
List<int> sampleRegion(NV21Frame f, NormRect region, int n) {
  final uw = f.uprightWidth, uh = f.uprightHeight;
  final res = <int>[];
  for (int j = 0; j < n; j++) {
    final uy = ((region.top + region.height * (j + 0.5) / n) * uh).floor().clamp(0, uh - 1);
    for (int i = 0; i < n; i++) {
      final ux = ((region.left + region.width * (i + 0.5) / n) * uw).floor().clamp(0, uw - 1);
      res.add(sampleRgb(f, ux, uy));
    }
  }
  return res;
}

/// Mean luma (0..255) of the frame, sampled sparsely.
double meanLuma(NV21Frame f) {
  int sum = 0, n = 0;
  final stepY = (f.height / 24).ceil(), stepX = (f.width / 24).ceil();
  for (int y = 0; y < f.height; y += stepY) {
    for (int x = 0; x < f.width; x += stepX) {
      sum += f.bytes[y * f.rowStride + x];
      n++;
    }
  }
  return n == 0 ? 0 : sum / n;
}

/// Builds a synthetic NV21 frame from an upright-agnostic RGB function.
/// Used by tests and the color calibration tools.
NV21Frame syntheticFrame(int w, int h, int Function(int x, int y) rgbAt, {int rotation = 0}) {
  final bytes = Uint8List(w * h + w * (h ~/ 2));
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final c = rgbAt(x, y);
      final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
      bytes[y * w + x] = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
      if (y % 2 == 0 && x % 2 == 0) {
        final idx = w * h + (y >> 1) * w + x;
        bytes[idx] = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128; // V
        bytes[idx + 1] = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128; // U
      }
    }
  }
  return NV21Frame(bytes: bytes, width: w, height: h, rotation: rotation);
}
