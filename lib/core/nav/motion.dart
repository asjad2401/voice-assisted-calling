import 'dart:math' as math;

/// Detects walking steps from raw accelerometer samples (m/s², gravity
/// included) using a smoothed magnitude with peak detection and a
/// refractory period.
class StepDetector {
  final double threshold; // m/s² above the running mean
  final int minIntervalMs;
  double _mean = 9.81;
  double _smooth = 9.81;
  bool _above = false;
  int _lastStepMs = -100000;
  int steps = 0;

  StepDetector({this.threshold = 1.2, this.minIntervalMs = 280});

  /// Feeds one sample; returns true if it completed a step.
  bool add(double x, double y, double z, int timestampMs) {
    final m = math.sqrt(x * x + y * y + z * z);
    _smooth = _smooth * 0.6 + m * 0.4;
    _mean = _mean * 0.98 + m * 0.02;
    final diff = _smooth - _mean;
    if (!_above && diff > threshold) {
      _above = true;
      if (timestampMs - _lastStepMs >= minIntervalMs) {
        _lastStepMs = timestampMs;
        steps++;
        return true;
      }
    } else if (_above && diff < threshold * 0.3) {
      _above = false;
    }
    return false;
  }

  void reset() {
    steps = 0;
  }
}

/// Tilt-compensated compass heading in degrees (0 = magnetic north,
/// clockwise) of the direction the user is facing.
///
/// When the phone is held upright (camera facing forward) the back-camera
/// axis is used; when it lies flat the top edge is used.
double? headingDegrees(
  double ax,
  double ay,
  double az, // gravity / accelerometer (device frame)
  double mx,
  double my,
  double mz, // magnetic field (device frame)
) {
  // East = M x A, North = A x East (as Android's getRotationMatrix).
  double hx = my * az - mz * ay;
  double hy = mz * ax - mx * az;
  double hz = mx * ay - my * ax;
  final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
  final normA = math.sqrt(ax * ax + ay * ay + az * az);
  if (normH < 0.1 || normA < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final gx = ax / normA, gy = ay / normA, gz = az / normA;
  final ny = gz * hx - gx * hz;
  final nz = gx * hy - gy * hx;
  double east, north;
  if (gz.abs() < 0.7) {
    // Upright: user faces where the back camera (-Z) points.
    east = -hz;
    north = -nz;
  } else {
    // Flat: top of the phone (+Y).
    east = hy;
    north = ny;
  }
  final deg = math.atan2(east, north) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// Signed smallest difference target - current in degrees (-180..180].
double angleDiff(double target, double current) {
  double d = (target - current) % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d;
}

/// Circular mean of headings in degrees.
double circularMean(Iterable<double> degs) {
  double s = 0, c = 0;
  for (final d in degs) {
    s += math.sin(d * math.pi / 180);
    c += math.cos(d * math.pi / 180);
  }
  final m = math.atan2(s, c) * 180 / math.pi;
  return (m + 360) % 360;
}

/// Spoken turn instruction for a heading change.
String turnPhrase(double delta) {
  final a = delta.abs();
  if (a < 20) return 'continue straight';
  final side = delta > 0 ? 'right' : 'left';
  if (a < 55) return 'turn slightly $side';
  if (a < 135) return 'turn $side';
  return 'turn around';
}

/// Smooths a heading stream with an exponential filter on the unit circle.
class HeadingFilter {
  final double alpha;
  double? _s, _c;
  HeadingFilter({this.alpha = 0.15});

  double? add(double deg) {
    final s = math.sin(deg * math.pi / 180), c = math.cos(deg * math.pi / 180);
    _s = _s == null ? s : _s! * (1 - alpha) + s * alpha;
    _c = _c == null ? c : _c! * (1 - alpha) + c * alpha;
    return value;
  }

  double? get value {
    if (_s == null) return null;
    final d = math.atan2(_s!, _c!) * 180 / math.pi;
    return (d + 360) % 360;
  }
}
