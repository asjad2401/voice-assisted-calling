import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../nav/route.dart';
import '../vision/embedding.dart';

/// Kinds of enrolled things kept in the gallery table.
class GalleryKind {
  static const person = 'person';
  static const object = 'object';
  static const landmark = 'landmark';
  static const clothing = 'clothing';
}

/// One row of the local activity log.
class ActivityEvent {
  final int id;
  final DateTime time;
  final String module;
  final String kind;
  final String text;
  final String? subject;

  const ActivityEvent(this.id, this.time, this.module, this.kind, this.text, this.subject);
}

/// All app data lives in one local SQLite database. Nothing leaves the
/// phone.
class Store {
  Store._();
  static final Store instance = Store._();

  Database? _db;

  /// For tests: use an in-memory or custom factory database.
  static DatabaseFactory? factoryOverride;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final factory = factoryOverride ?? databaseFactory;
    final path = factoryOverride != null ? inMemoryDatabasePath : p.join(await getDatabasesPath(), 'vision_assist.db');
    _db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, v) async {
          await d.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
          await d.execute(
              'CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, module TEXT, kind TEXT, text TEXT, subject TEXT)');
          await d.execute('CREATE INDEX events_ts ON events(ts)');
          await d.execute(
              'CREATE TABLE gallery (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, name TEXT, created INTEGER, extra TEXT)');
          await d.execute(
              'CREATE TABLE samples (id INTEGER PRIMARY KEY AUTOINCREMENT, gallery_id INTEGER REFERENCES gallery(id) ON DELETE CASCADE, vec BLOB)');
          await d.execute(
              'CREATE TABLE routes (id INTEGER PRIMARY KEY AUTOINCREMENT, src TEXT, dst TEXT, segments TEXT, created INTEGER)');
        },
      ),
    );
    return _db!;
  }

  Future<void> closeForTests() async {
    await _db?.close();
    _db = null;
  }

  // ---- key/value settings -------------------------------------------------

  Future<String?> getString(String k) async {
    final r = await (await db).query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> setString(String k, String v) async {
    await (await db).insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getJson(String k) async {
    final s = await getString(k);
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  Future<void> setJson(String k, Map<String, dynamic> v) => setString(k, jsonEncode(v));

  // ---- activity log -------------------------------------------------------

  Future<void> logEvent(String module, String kind, String text, {String? subject, DateTime? at}) async {
    await (await db).insert('events', {
      'ts': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'module': module,
      'kind': kind,
      'text': text,
      'subject': subject?.toLowerCase(),
    });
  }

  Future<List<ActivityEvent>> events({DateTime? since, String? subject, String? kind, int limit = 50}) async {
    final where = <String>[];
    final args = <Object>[];
    if (since != null) {
      where.add('ts >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (subject != null) {
      where.add('subject = ?');
      args.add(subject.toLowerCase());
    }
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind);
    }
    final rows = await (await db).query('events',
        where: where.isEmpty ? null : where.join(' AND '),
        whereArgs: args.isEmpty ? null : args,
        orderBy: 'ts DESC',
        limit: limit);
    return rows
        .map((r) => ActivityEvent(
              r['id'] as int,
              DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
              r['module'] as String,
              r['kind'] as String,
              r['text'] as String,
              r['subject'] as String?,
            ))
        .toList();
  }

  Future<int> clearEvents() async => (await db).delete('events');

  Future<int> pruneEvents(Duration keep) async =>
      (await db).delete('events', where: 'ts < ?', whereArgs: [DateTime.now().subtract(keep).millisecondsSinceEpoch]);

  // ---- gallery (people, objects, places, clothes) ---------------------------

  Future<int> addGalleryEntry(String kind, String name, List<Float32List> samples,
      {Map<String, Object?> extra = const {}}) async {
    final d = await db;
    return d.transaction((txn) async {
      final id = await txn.insert('gallery', {
        'kind': kind,
        'name': name,
        'created': DateTime.now().millisecondsSinceEpoch,
        'extra': jsonEncode(extra),
      });
      for (final s in samples) {
        await txn.insert('samples', {'gallery_id': id, 'vec': embeddingToBytes(s)});
      }
      return id;
    });
  }

  Future<void> addSamples(int galleryId, List<Float32List> samples) async {
    final d = await db;
    final batch = d.batch();
    for (final s in samples) {
      batch.insert('samples', {'gallery_id': galleryId, 'vec': embeddingToBytes(s)});
    }
    await batch.commit(noResult: true);
  }

  Future<List<GalleryEntry>> gallery(String kind) async {
    final d = await db;
    final rows = await d.query('gallery', where: 'kind = ?', whereArgs: [kind], orderBy: 'name');
    final res = <GalleryEntry>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final s = await d.query('samples', where: 'gallery_id = ?', whereArgs: [id]);
      res.add(GalleryEntry(
        id,
        r['name'] as String,
        s.map((x) => embeddingFromBytes(x['vec'] as Uint8List)).toList(),
        extra: (jsonDecode((r['extra'] as String?) ?? '{}') as Map).cast<String, Object?>(),
      ));
    }
    return res;
  }

  Future<void> deleteGalleryEntry(int id) async => (await db).delete('gallery', where: 'id = ?', whereArgs: [id]);

  // ---- routes -------------------------------------------------------------

  Future<int> saveRoute(SavedRoute r) async => (await db).insert('routes', {
        'src': r.from,
        'dst': r.to,
        'segments': r.segmentsJson(),
        'created': DateTime.now().millisecondsSinceEpoch,
      });

  Future<List<SavedRoute>> routes() async {
    final rows = await (await db).query('routes', orderBy: 'created DESC');
    return rows
        .map((r) => SavedRoute(
              id: r['id'] as int,
              from: r['src'] as String,
              to: r['dst'] as String,
              segments: SavedRoute.parseSegments(r['segments'] as String),
            ))
        .toList();
  }

  Future<void> deleteRoutesFor(String place) async =>
      (await db).delete('routes', where: 'src = ? OR dst = ?', whereArgs: [place, place]);
}
