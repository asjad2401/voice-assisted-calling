import 'dart:math' as math;

/// CIE L*a*b* color.
class Lab {
  final double l, a, b;
  const Lab(this.l, this.a, this.b);

  double distance(Lab o) {
    final dl = l - o.l, da = a - o.a, db = b - o.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }

  double get chroma => math.sqrt(a * a + b * b);

  /// Hue angle in degrees 0..360.
  double get hue {
    final h = math.atan2(b, a) * 180 / math.pi;
    return h < 0 ? h + 360 : h;
  }
}

double _srgbToLinear(int c) {
  final v = c / 255.0;
  return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

double _f(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : (7.787 * t + 16 / 116);

Lab rgbToLab(int rgb) {
  final r = _srgbToLinear((rgb >> 16) & 0xFF);
  final g = _srgbToLinear((rgb >> 8) & 0xFF);
  final b = _srgbToLinear(rgb & 0xFF);
  final x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
  final y = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 1.0;
  final z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;
  final fx = _f(x), fy = _f(y), fz = _f(z);
  return Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

/// A named reference color with the "family" used for outfit matching.
class NamedColor {
  final String name;
  final String family;
  final int rgb;
  final Lab lab;
  NamedColor(this.name, this.family, this.rgb) : lab = rgbToLab(rgb);
}

/// Families that go with nearly everything.
const Set<String> neutralFamilies = {'black', 'white', 'grey', 'beige', 'brown', 'navy', 'denim'};

final List<NamedColor> palette = [
  NamedColor('black', 'black', 0x111111),
  NamedColor('dark grey', 'grey', 0x4A4A4A),
  NamedColor('grey', 'grey', 0x808080),
  NamedColor('light grey', 'grey', 0xC0C0C0),
  NamedColor('white', 'white', 0xF5F5F5),
  NamedColor('off white', 'white', 0xEDE6D6),
  NamedColor('cream', 'beige', 0xF3E5AB),
  NamedColor('beige', 'beige', 0xD8C3A5),
  NamedColor('khaki', 'beige', 0xB5A77A),
  NamedColor('tan', 'brown', 0xC19A6B),
  NamedColor('light brown', 'brown', 0xA0703C),
  NamedColor('brown', 'brown', 0x6B4226),
  NamedColor('dark brown', 'brown', 0x3E2616),
  NamedColor('maroon', 'red', 0x6A0F1A),
  NamedColor('dark red', 'red', 0x9B111E),
  NamedColor('red', 'red', 0xD0202A),
  NamedColor('coral', 'orange', 0xF0776A),
  NamedColor('salmon pink', 'pink', 0xF4A3A0),
  NamedColor('pink', 'pink', 0xF7A8C4),
  NamedColor('hot pink', 'pink', 0xE8448F),
  NamedColor('magenta', 'purple', 0xC2187B),
  NamedColor('orange', 'orange', 0xF07B16),
  NamedColor('dark orange', 'orange', 0xB85412),
  NamedColor('peach', 'orange', 0xF8C49A),
  NamedColor('mustard', 'yellow', 0xC9A227),
  NamedColor('gold', 'yellow', 0xD4AF37),
  NamedColor('yellow', 'yellow', 0xF5D716),
  NamedColor('light yellow', 'yellow', 0xF9EE99),
  NamedColor('olive', 'green', 0x6B6B1E),
  NamedColor('lime green', 'green', 0x9ACD32),
  NamedColor('light green', 'green', 0x98D98E),
  NamedColor('green', 'green', 0x2E9A3E),
  NamedColor('dark green', 'green', 0x1B4D2B),
  NamedColor('bottle green', 'green', 0x0B3B24),
  NamedColor('mint', 'green', 0xBDE8CF),
  NamedColor('teal', 'teal', 0x137B7B),
  NamedColor('turquoise', 'teal', 0x3CC8C0),
  NamedColor('sky blue', 'blue', 0x87C3EB),
  NamedColor('light blue', 'blue', 0xADCBE3),
  NamedColor('denim blue', 'denim', 0x3B5C85),
  NamedColor('blue', 'blue', 0x2156C9),
  NamedColor('royal blue', 'blue', 0x2A3FBF),
  NamedColor('navy blue', 'navy', 0x1B2545),
  NamedColor('lavender', 'purple', 0xC6B4E3),
  NamedColor('purple', 'purple', 0x6A2C91),
  NamedColor('violet', 'purple', 0x8A4FD0),
  NamedColor('plum', 'purple', 0x5E2750),
];

NamedColor nearestColor(int rgb) {
  final lab = rgbToLab(rgb);
  NamedColor best = palette.first;
  double bestD = double.infinity;
  for (final c in palette) {
    final d = lab.distance(c.lab);
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

/// A cluster of similar colors found in a region.
class ColorShare {
  final NamedColor color;
  final double fraction;
  final int meanRgb;
  const ColorShare(this.color, this.fraction, this.meanRgb);
}

/// Finds up to [k] dominant colors among [samples] (packed RGB) using
/// k-means in Lab space, merges clusters that map to the same name and
/// returns them sorted by share.
List<ColorShare> dominantColors(List<int> samples, {int k = 4, int iterations = 8}) {
  if (samples.isEmpty) return const [];
  final labs = samples.map(rgbToLab).toList();
  final rnd = math.Random(7);
  // k-means++ style seeding for stable results.
  final centers = <Lab>[labs[rnd.nextInt(labs.length)]];
  while (centers.length < k && centers.length < labs.length) {
    Lab far = labs.first;
    double farD = -1;
    for (final p in labs) {
      final d = centers.map((c) => c.distance(p)).reduce(math.min);
      if (d > farD) {
        farD = d;
        far = p;
      }
    }
    if (farD < 4) break; // everything is basically the same color
    centers.add(far);
  }
  final assign = List<int>.filled(labs.length, 0);
  for (int it = 0; it < iterations; it++) {
    for (int i = 0; i < labs.length; i++) {
      double bd = double.infinity;
      for (int c = 0; c < centers.length; c++) {
        final d = labs[i].distance(centers[c]);
        if (d < bd) {
          bd = d;
          assign[i] = c;
        }
      }
    }
    for (int c = 0; c < centers.length; c++) {
      double l = 0, a = 0, b = 0;
      int n = 0;
      for (int i = 0; i < labs.length; i++) {
        if (assign[i] == c) {
          l += labs[i].l;
          a += labs[i].a;
          b += labs[i].b;
          n++;
        }
      }
      if (n > 0) centers[c] = Lab(l / n, a / n, b / n);
    }
  }
  // Aggregate by name.
  final byName = <String, List<int>>{};
  for (int i = 0; i < samples.length; i++) {
    final name = _nearestToLab(centers[assign[i]]).name;
    byName.putIfAbsent(name, () => []).add(samples[i]);
  }
  final res = byName.entries.map((e) {
    final named = palette.firstWhere((p) => p.name == e.key);
    return ColorShare(named, e.value.length / samples.length, _meanRgb(e.value));
  }).toList()
    ..sort((a, b) => b.fraction.compareTo(a.fraction));
  return res;
}

NamedColor _nearestToLab(Lab lab) {
  NamedColor best = palette.first;
  double bestD = double.infinity;
  for (final c in palette) {
    final d = lab.distance(c.lab);
    if (d < bestD) {
      bestD = d;
      best = c;
    }
  }
  return best;
}

int _meanRgb(List<int> s) {
  int r = 0, g = 0, b = 0;
  for (final c in s) {
    r += (c >> 16) & 0xFF;
    g += (c >> 8) & 0xFF;
    b += c & 0xFF;
  }
  final n = s.length;
  return ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
}

/// Describes the color mix of a garment-sized region.
String describeColorMix(List<ColorShare> shares) {
  final significant = shares.where((s) => s.fraction >= 0.12).toList();
  if (significant.isEmpty) return 'unclear colors';
  if (significant.length == 1 || significant.first.fraction > 0.8) {
    return 'solid ${significant.first.color.name}';
  }
  final names = significant.take(3).map((s) => s.color.name).toList();
  final mainPct = (significant.first.fraction * 100).round();
  if (names.length == 2) {
    return 'mostly ${names[0]}, about $mainPct percent, with ${names[1]}';
  }
  return 'mixed ${names[0]}, ${names[1]} and ${names[2]}; possibly a pattern or print';
}

/// Spoken light level from mean luma 0..255.
String lightLevel(double luma) {
  if (luma < 25) return 'very dark';
  if (luma < 60) return 'dim';
  if (luma < 140) return 'moderately lit';
  if (luma < 200) return 'bright';
  return 'very bright';
}

/// Verdict for whether two garment colors pair well, with a short reason.
class MatchVerdict {
  final bool goesWell;
  final String reason;
  const MatchVerdict(this.goesWell, this.reason);
}

MatchVerdict colorsMatch(NamedColor a, NamedColor b) {
  if (neutralFamilies.contains(a.family) || neutralFamilies.contains(b.family)) {
    final neutral = neutralFamilies.contains(a.family) ? a : b;
    if (a.family == 'navy' && b.family == 'black' || a.family == 'black' && b.family == 'navy') {
      return const MatchVerdict(false, 'navy and black are hard to tell apart and can look like a mismatch');
    }
    if (a.family == 'brown' && b.family == 'black' || a.family == 'black' && b.family == 'brown') {
      return const MatchVerdict(true, 'brown and black can work, though some people prefer to keep them apart');
    }
    return MatchVerdict(true, '${neutral.name} is a neutral color that goes with most things');
  }
  if (a.family == b.family) {
    return MatchVerdict(true, 'both are shades of ${a.family}, a matching tone-on-tone look');
  }
  final dh = (a.lab.hue - b.lab.hue).abs();
  final hueGap = dh > 180 ? 360 - dh : dh;
  const clashes = {
    {'red', 'pink'},
    {'red', 'orange'},
    {'orange', 'pink'},
    {'red', 'purple'},
    {'green', 'red'},
    {'yellow', 'purple'},
    {'orange', 'purple'},
  };
  for (final pair in clashes) {
    if (pair.contains(a.family) && pair.contains(b.family)) {
      return MatchVerdict(false, '${a.name} and ${b.name} usually clash');
    }
  }
  if (a.lab.chroma > 45 && b.lab.chroma > 45 && hueGap > 60) {
    return MatchVerdict(
        false, '${a.name} and ${b.name} are both strong colors; pair one of them with a neutral instead');
  }
  return MatchVerdict(true, '${a.name} and ${b.name} can go well together');
}
