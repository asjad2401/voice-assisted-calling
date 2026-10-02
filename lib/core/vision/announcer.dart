/// Decides which live detections are worth speaking, so the user hears
/// "chair on your left" once when it appears instead of every frame.
///
/// A label must be seen in [minHits] consecutive updates before it is
/// announced, and is then held back for [cooldown] unless it disappears
/// for longer than [forgetAfter] and comes back, or changes direction.
class Announcer<T> {
  final int minHits;
  final Duration cooldown;
  final Duration forgetAfter;
  final Map<String, _Track> _tracks = {};

  Announcer({
    this.minHits = 2,
    this.cooldown = const Duration(seconds: 12),
    this.forgetAfter = const Duration(seconds: 4),
  });

  /// [items] maps a key (e.g. label) to (item, directionWord).
  List<T> update(Map<String, (T, String)> items, DateTime now) {
    final out = <T>[];
    for (final e in items.entries) {
      final t = _tracks.putIfAbsent(e.key, () => _Track());
      final gap = t.lastSeen == null ? null : now.difference(t.lastSeen!);
      if (gap != null && gap > forgetAfter) {
        t.hits = 0;
        t.lastAnnounced = null;
      }
      t.hits++;
      t.lastSeen = now;
      final dir = e.value.$2;
      final cooled = t.lastAnnounced == null || now.difference(t.lastAnnounced!) > cooldown;
      final moved = t.lastDirection != null && t.lastDirection != dir && t.hits >= minHits + 2;
      if (t.hits >= minHits && (cooled || moved)) {
        t.lastAnnounced = now;
        t.lastDirection = dir;
        out.add(e.value.$1);
      }
    }
    // Labels not seen this round lose their streak.
    for (final k in _tracks.keys) {
      if (!items.containsKey(k)) _tracks[k]!.hits = 0;
    }
    return out;
  }

  void reset() => _tracks.clear();
}

class _Track {
  int hits = 0;
  DateTime? lastSeen;
  DateTime? lastAnnounced;
  String? lastDirection;
}
