import 'package:flutter/material.dart';

import '../core/commands.dart';
import '../core/storage/store.dart';
import '../core/vision/detection.dart';
import 'module.dart';
import 'objects_module.dart' show timeAgo;

/// One-paragraph summary of a day's events.
String summarizeEvents(List<ActivityEvent> events, {String period = 'Today'}) {
  if (events.isEmpty) return '$period there is nothing in your activity log yet.';
  final counts = <String, int>{};
  for (final e in events) {
    counts[e.kind] = (counts[e.kind] ?? 0) + 1;
  }
  final parts = <String>[];
  void add(String kind, String one, String many) {
    final n = counts[kind];
    if (n == null) return;
    parts.add(n == 1 ? one : many.replaceAll('#', '$n'));
  }

  add('read', 'read one text', 'read # texts');
  add('scene', 'described one scene', 'described # scenes');
  add('currency', 'identified one note', 'identified # notes');
  add('call', 'made one call', 'made # calls');
  add('incoming', 'received one call', 'received # calls');
  add('clothing', 'checked clothing once', 'checked clothing # times');
  add('navigation', 'used navigation once', 'used navigation # times');
  add('emergency', 'sent an emergency alert', 'sent # emergency alerts');
  final people = events
      .where((e) => e.kind == 'person' && e.text.startsWith('Saw '))
      .map((e) => e.subject)
      .whereType<String>()
      .toSet();
  if (people.isNotEmpty) parts.add('met ${joinSpoken(people.map(_cap).toList())}');
  final objects = events.where((e) => e.kind == 'sighting').map((e) => e.subject).whereType<String>().toSet();
  if (objects.isNotEmpty) parts.add('spotted your ${joinSpoken(objects.toList())}');
  if (parts.isEmpty) return '$period you have ${events.length} log entries.';
  return '$period you ${joinSpoken(parts)}.';
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Local activity log: everything the app recognized or did, stored only
/// on the phone, searchable by voice.
class ActivityModule extends AssistModule {
  @override
  String get id => 'activity';
  @override
  String get title => 'Activity log';
  @override
  IconData get icon => Icons.history;
  @override
  Color get color => const Color(0xFF3A3A3A);
  @override
  String get hint =>
      'Tap to hear your latest activity. Double tap for a summary of today. You can ask "where did I leave my keys".';
  @override
  String get help =>
      'The activity log keeps a private diary on this phone of what the app did: texts read, notes counted, people met, calls, places, and where your saved objects were last seen. '
      'Tap to hear the five latest entries; tap again for older ones. Double tap for a summary of today. Ask "where did I leave my wallet" or "what did I do today". '
      'Say "clear history" to delete everything. Entries older than 30 days are removed automatically.';
  @override
  String get tapLabel => 'Latest activity';
  @override
  String get doubleTapLabel => "Today's summary";

  @override
  bool get usesCamera => false;

  int _page = 0;

  @override
  Future<void> onEnter() async {
    _page = 0;
    await store.pruneEvents(const Duration(days: 30));
    final today = await store.events(since: _startOfToday(), limit: 500);
    status = summarizeEvents(today);
  }

  DateTime _startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  Future<void> onTap() async {
    final all = await store.events(limit: 5 * (_page + 1));
    final page = all.skip(5 * _page).toList();
    if (page.isEmpty) {
      final wasFirst = _page == 0;
      _page = 0;
      return say(wasFirst ? 'The activity log is empty.' : 'No older entries. Starting again from the latest.');
    }
    final now = DateTime.now();
    final lines = page.map((e) => '${timeAgo(e.time, now)}: ${e.text}.').join(' ');
    status = lines;
    _page++;
    await say(lines);
  }

  @override
  Future<void> onDoubleTap() async {
    final today = await store.events(since: _startOfToday(), limit: 500);
    final s = summarizeEvents(today);
    status = s;
    await say(s);
  }

  Future<void> whereLast(String what) async {
    final q = normalizeUtterance(what).replaceFirst(RegExp(r'^(my|the) '), '');
    final events = await store.events(limit: 300);
    final subjects = events.map((e) => e.subject).whereType<String>().toSet();
    final name = matchName(q, subjects);
    if (name == null) return say('I have no record of $q.');
    final e = events.firstWhere((e) => e.subject == name);
    await say(
        '${timeAgo(e.time, DateTime.now())[0].toUpperCase()}${timeAgo(e.time, DateTime.now()).substring(1)}: ${e.text}.');
  }

  @override
  Future<bool> handle(Command c) async {
    switch (c.intent) {
      case VoiceIntent.activityToday:
        await onDoubleTap();
        return true;
      case VoiceIntent.whereLast:
        await whereLast(c.arg ?? '');
        return true;
      case VoiceIntent.clearLog:
        if (await host.confirm('Delete your whole activity history?')) {
          await store.clearEvents();
          status = 'History cleared';
          await say('History deleted.');
        } else {
          await say('Kept.');
        }
        return true;
      default:
        return false;
    }
  }
}
