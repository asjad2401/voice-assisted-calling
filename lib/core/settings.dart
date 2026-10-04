import 'storage/store.dart';

/// User preferences, persisted locally.
class Settings {
  Settings._();
  static final Settings instance = Settings._();

  double speechRate = 0.5;
  bool verbose = true;
  bool haptics = true;
  bool shakeForSos = true;
  bool tutorialDone = false;
  bool overlayPrompted = false;
  bool useClockDirections = false;
  String lastModeId = 'explore';
  Map<String, int> hintCounts = {};

  Future<void> load() async {
    final m = await Store.instance.getJson('settings');
    if (m == null) return;
    speechRate = (m['speechRate'] as num?)?.toDouble() ?? speechRate;
    verbose = m['verbose'] as bool? ?? verbose;
    haptics = m['haptics'] as bool? ?? haptics;
    shakeForSos = m['shakeForSos'] as bool? ?? shakeForSos;
    tutorialDone = m['tutorialDone'] as bool? ?? tutorialDone;
    overlayPrompted = m['overlayPrompted'] as bool? ?? overlayPrompted;
    useClockDirections = m['clock'] as bool? ?? useClockDirections;
    lastModeId = m['lastMode'] as String? ?? lastModeId;
    hintCounts = ((m['hints'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v as int));
  }

  Future<void> save() => Store.instance.setJson('settings', {
        'speechRate': speechRate,
        'verbose': verbose,
        'haptics': haptics,
        'shakeForSos': shakeForSos,
        'tutorialDone': tutorialDone,
        'overlayPrompted': overlayPrompted,
        'clock': useClockDirections,
        'lastMode': lastModeId,
        'hints': hintCounts,
      });

  /// Full spoken hints are given the first few times a mode is opened (or
  /// always in verbose mode); after that only the mode name.
  bool shouldGiveHint(String modeId) {
    final n = hintCounts[modeId] ?? 0;
    hintCounts[modeId] = n + 1;
    return verbose || n < 3;
  }
}
