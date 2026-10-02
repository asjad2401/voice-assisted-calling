import 'dart:convert';

import 'motion.dart';

/// A straight leg of a recorded route.
class RouteSegment {
  final int steps;
  final double heading; // degrees, magnetic

  const RouteSegment(this.steps, this.heading);

  Map<String, Object> toJson() => {'s': steps, 'h': heading};
  factory RouteSegment.fromJson(Map m) => RouteSegment(m['s'] as int, (m['h'] as num).toDouble());
}

/// A walkable path between two saved landmarks.
class SavedRoute {
  final int? id;
  final String from;
  final String to;
  final List<RouteSegment> segments;

  const SavedRoute({this.id, required this.from, required this.to, required this.segments});

  int get totalSteps => segments.fold(0, (a, s) => a + s.steps);

  SavedRoute reversed() => SavedRoute(
        from: to,
        to: from,
        segments: segments.reversed.map((s) => RouteSegment(s.steps, (s.heading + 180) % 360)).toList(),
      );

  String segmentsJson() => jsonEncode(segments.map((s) => s.toJson()).toList());

  static List<RouteSegment> parseSegments(String json) =>
      (jsonDecode(json) as List).map((m) => RouteSegment.fromJson(m as Map)).toList();

  /// Human-readable summary such as "12 steps, turn left, 8 steps".
  String describe() {
    final parts = <String>[];
    for (int i = 0; i < segments.length; i++) {
      if (i > 0) {
        parts.add(turnPhrase(angleDiff(segments[i].heading, segments[i - 1].heading)));
      }
      parts.add('${segments[i].steps} steps');
    }
    return parts.join(', ');
  }
}

/// Builds route segments from a stream of (step, heading) events.
class RouteRecorder {
  final double turnThreshold;
  final List<_Leg> _legs = [];
  final List<double> _recent = [];

  RouteRecorder({this.turnThreshold = 40});

  int get totalSteps => _legs.fold(0, (a, l) => a + l.headings.length);

  /// Records one step taken while facing [heading]. Returns true if this
  /// step started a new leg (i.e. the user turned).
  bool addStep(double heading) {
    _recent.add(heading);
    if (_recent.length > 3) _recent.removeAt(0);
    if (_legs.isEmpty) {
      _legs.add(_Leg()..headings.add(heading));
      return false;
    }
    final current = _legs.last;
    final legMean = circularMean(
        current.headings.length > 6 ? current.headings.sublist(current.headings.length - 6) : current.headings);
    if (_recent.length == 3 && _recent.every((h) => angleDiff(h, legMean).abs() > turnThreshold)) {
      // The last three steps all point elsewhere: they form a new leg.
      final moved = current.headings.length >= 2 ? current.headings.sublist(current.headings.length - 2) : <double>[];
      current.headings.removeRange(current.headings.length - moved.length, current.headings.length);
      _legs.add(_Leg()..headings.addAll([...moved, heading]));
      _recent.clear();
      return true;
    }
    current.headings.add(heading);
    return false;
  }

  /// Final list of segments, with tiny legs merged into their neighbors.
  List<RouteSegment> finish() {
    final legs = _legs.where((l) => l.headings.isNotEmpty).toList();
    final segs = <RouteSegment>[];
    for (final l in legs) {
      final seg = RouteSegment(l.headings.length, circularMean(l.headings));
      if (segs.isNotEmpty && (seg.steps < 2 || angleDiff(seg.heading, segs.last.heading).abs() < turnThreshold / 2)) {
        final prev = segs.removeLast();
        final total = prev.steps + seg.steps;
        segs.add(RouteSegment(total, prev.steps >= seg.steps ? prev.heading : seg.heading));
      } else {
        segs.add(seg);
      }
    }
    return segs;
  }
}

class _Leg {
  final List<double> headings = [];
}

/// Kinds of guidance prompts emitted while following a route.
enum GuideEventKind { start, progress, turnSoon, turn, aligned, offCourse, arrived }

class GuideEvent {
  final GuideEventKind kind;
  final String message;
  const GuideEvent(this.kind, this.message);
}

/// Step-by-step guidance along a [SavedRoute] using step counts and the
/// compass heading.
class RouteGuide {
  final SavedRoute route;
  int _seg = 0;
  int _stepsInSeg = 0;
  bool _awaitingAlign = false;
  int _offCourseSteps = 0;
  bool _arrived = false;
  bool _warnedSoon = false;

  RouteGuide(this.route);

  bool get arrived => _arrived;
  int get segmentIndex => _seg;
  double get targetHeading => route.segments[_seg].heading;
  int get stepsRemainingInSegment => route.segments[_seg].steps - _stepsInSeg;

  GuideEvent start(double? currentHeading) {
    final first = route.segments.first;
    // Already facing the right way: no separate "aligned" prompt needed.
    _awaitingAlign = currentHeading == null || angleDiff(first.heading, currentHeading).abs() >= 22;
    final turn =
        currentHeading == null ? '' : '${_capitalize(turnPhrase(angleDiff(first.heading, currentHeading)))}, then ';
    return GuideEvent(GuideEventKind.start,
        'Route to ${route.to}: ${route.totalSteps} steps in total. ${turn}walk about ${first.steps} steps.');
  }

  /// Called when the heading changes while waiting for the user to face
  /// the next leg; returns an event once they are aligned.
  GuideEvent? onHeading(double heading) {
    if (_arrived || !_awaitingAlign) return null;
    if (angleDiff(targetHeading, heading).abs() < 22) {
      _awaitingAlign = false;
      return GuideEvent(GuideEventKind.aligned, 'Good. Walk about $stepsRemainingInSegment steps.');
    }
    return null;
  }

  GuideEvent? onStep(double? heading) {
    if (_arrived) return null;
    _stepsInSeg++;
    if (heading != null) {
      final err = angleDiff(targetHeading, heading);
      if (err.abs() > 45) {
        _offCourseSteps++;
      } else {
        _offCourseSteps = 0;
        _awaitingAlign = false;
      }
      if (_offCourseSteps == 3) {
        _offCourseSteps = 0;
        return GuideEvent(GuideEventKind.offCourse, 'You are drifting. ${_capitalize(turnPhrase(err))}.');
      }
    }
    final remaining = stepsRemainingInSegment;
    final isLast = _seg == route.segments.length - 1;
    if (remaining <= 0) {
      if (isLast) {
        _arrived = true;
        return GuideEvent(GuideEventKind.arrived, 'You should now be at ${route.to}.');
      }
      final next = route.segments[_seg + 1];
      final turn = turnPhrase(angleDiff(next.heading, route.segments[_seg].heading));
      _seg++;
      _stepsInSeg = 0;
      _warnedSoon = false;
      _awaitingAlign = true;
      return GuideEvent(GuideEventKind.turn, '${_capitalize(turn)} now.');
    }
    if (remaining == 3 && !_warnedSoon) {
      _warnedSoon = true;
      if (isLast) {
        return GuideEvent(GuideEventKind.turnSoon, '3 more steps to ${route.to}.');
      }
      final next = route.segments[_seg + 1];
      final turn = turnPhrase(angleDiff(next.heading, route.segments[_seg].heading));
      return GuideEvent(GuideEventKind.turnSoon, '3 more steps, then $turn.');
    }
    if (_stepsInSeg % 10 == 0) {
      return GuideEvent(GuideEventKind.progress, '$remaining steps to go on this stretch.');
    }
    return null;
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Finds a walkable route between two places by chaining recorded routes
/// (each usable in both directions). Returns null if they are not
/// connected. Uses breadth-first search, so the fewest hops win, and among
/// direct routes the shortest one.
SavedRoute? findRoute(List<SavedRoute> routes, String from, String to) {
  String k(String s) => s.toLowerCase().trim();
  final edges = <String, List<SavedRoute>>{};
  for (final r in routes) {
    edges.putIfAbsent(k(r.from), () => []).add(r);
    final back = r.reversed();
    edges.putIfAbsent(k(back.from), () => []).add(back);
  }
  for (final list in edges.values) {
    list.sort((a, b) => a.totalSteps.compareTo(b.totalSteps));
  }
  final start = k(from), goal = k(to);
  if (start == goal) return null;
  final prev = <String, SavedRoute>{};
  final queue = <String>[start];
  final visited = {start};
  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    if (cur == goal) break;
    for (final e in edges[cur] ?? const <SavedRoute>[]) {
      final nxt = k(e.to);
      if (visited.add(nxt)) {
        prev[nxt] = e;
        queue.add(nxt);
      }
    }
  }
  if (!prev.containsKey(goal)) return null;
  final chain = <SavedRoute>[];
  var node = goal;
  while (node != start) {
    final e = prev[node]!;
    chain.insert(0, e);
    node = k(e.from);
  }
  return SavedRoute(
    from: chain.first.from,
    to: chain.last.to,
    segments: [for (final r in chain) ...r.segments],
  );
}
