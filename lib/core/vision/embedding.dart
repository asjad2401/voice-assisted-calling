import 'dart:math' as math;
import 'dart:typed_data';

Float32List l2Normalize(Float32List v) {
  double s = 0;
  for (final x in v) {
    s += x * x;
  }
  final n = math.sqrt(s);
  if (n == 0) return v;
  final out = Float32List(v.length);
  for (int i = 0; i < v.length; i++) {
    out[i] = v[i] / n;
  }
  return out;
}

/// Cosine similarity; both inputs are expected to be L2-normalized.
double cosine(Float32List a, Float32List b) {
  if (a.length != b.length) return 0;
  double s = 0;
  for (int i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

Uint8List embeddingToBytes(Float32List v) => v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);

Float32List embeddingFromBytes(Uint8List b) {
  final copy = Uint8List.fromList(b);
  return copy.buffer.asFloat32List();
}

/// One enrolled thing (a person, object or place) with several reference
/// embeddings captured from different angles.
class GalleryEntry {
  final int id;
  final String name;
  final List<Float32List> samples;
  final Map<String, Object?> extra;

  GalleryEntry(this.id, this.name, this.samples, {this.extra = const {}});
}

class GalleryMatch {
  final GalleryEntry entry;
  final double score;

  /// Gap between this score and the best score of any other entry; a small
  /// margin means the match is ambiguous.
  final double margin;
  const GalleryMatch(this.entry, this.score, this.margin);
}

/// Scores [query] against each entry using the mean of its top-2 sample
/// similarities (robust to one bad enrollment shot).
GalleryMatch? bestGalleryMatch(
  Float32List query,
  List<GalleryEntry> gallery, {
  required double threshold,
  double minMargin = 0.0,
}) {
  GalleryEntry? best;
  double bestScore = -1, second = -1;
  for (final e in gallery) {
    if (e.samples.isEmpty) continue;
    final sims = e.samples.map((s) => cosine(query, s)).toList()..sort((a, b) => b.compareTo(a));
    final score = sims.length >= 2 ? (sims[0] + sims[1]) / 2 : sims[0];
    if (score > bestScore) {
      second = bestScore;
      bestScore = score;
      best = e;
    } else if (score > second) {
      second = score;
    }
  }
  if (best == null || bestScore < threshold) return null;
  final margin = second < 0 ? 1.0 : bestScore - second;
  if (margin < minMargin) return null;
  return GalleryMatch(best, bestScore, margin);
}
