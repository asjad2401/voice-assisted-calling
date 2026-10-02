/// Spoken command understanding. Pure Dart so it can be unit tested and
/// works entirely offline: the speech recognizer gives us text, and this
/// maps it to an intent with an optional argument.
enum VoiceIntent {
  describeScene,
  whatsAhead,
  readText,
  currency,
  color,
  lightLevel,
  clothing,
  matchClothes,
  whoIsHere,
  savePerson,
  findObject,
  saveObject,
  listSaved,
  whereAmI,
  saveLandmark,
  navigateTo,
  recordRoute,
  stopNavigation,
  call,
  emergency,
  medicalInfo,
  activityToday,
  whereLast,
  clearLog,
  time,
  date,
  help,
  repeat,
  stop,
  faster,
  slower,
  brief,
  verbose,
  obstacles,
  openMode,
  cancel,
  yes,
  no,
  unknown,
}

class Command {
  final VoiceIntent intent;
  final String? arg;
  final String raw;
  const Command(this.intent, this.raw, [this.arg]);

  @override
  String toString() => 'Command($intent, ${arg ?? ''})';
}

/// Mode identifiers used by [VoiceIntent.openMode].
const Map<String, List<String>> modeAliases = {
  'explore': ['explore', 'object', 'objects mode', 'scene', 'surroundings'],
  'obstacles': ['obstacle', 'walking', 'walk mode'],
  'text': ['text', 'reader', 'reading'],
  'currency': ['currency', 'money', 'cash', 'notes'],
  'color': ['color', 'colour', 'clothing', 'clothes'],
  'people': ['people', 'faces', 'face', 'person'],
  'objects': ['my objects', 'find mode', 'saved objects', 'object finder'],
  'places': ['places', 'navigation', 'landmark', 'indoor'],
  'calls': ['calls', 'phone', 'dialer', 'calling'],
  'emergency': ['emergency', 'sos', 'medical'],
  'activity': ['activity', 'log', 'history', 'diary'],
};

String normalizeUtterance(String s) {
  var t = s.toLowerCase().trim().replaceAll(RegExp(r"['’]"), '');
  t = t.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  const fillers = [
    'please',
    'can you',
    'could you',
    'would you',
    'hey',
    'ok',
    'okay',
    'assistant',
    'i want to',
    'i want you to',
    'i would like to',
    'tell me',
    'kindly',
    'now',
  ];
  for (final f in fillers) {
    t = t.replaceAll(RegExp('(^| )$f( |\$)'), ' ');
  }
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _has(String t, List<String> words) => words.any((w) => RegExp('(^| )$w( |\$)').hasMatch(t));

String? _after(String t, List<String> prefixes) {
  for (final p in prefixes) {
    final m = RegExp('(^| )$p (.+)\$').firstMatch(t);
    if (m != null) {
      var rest = m.group(2)!.trim();
      rest = rest.replaceFirst(RegExp(r'^(my|the|a|an|to|for) '), '');
      rest = rest.replaceFirst(RegExp(r'^(my|the|a|an) '), '');
      if (rest.isNotEmpty) return rest;
    }
  }
  return null;
}

Command parseCommand(String utterance) {
  final raw = utterance;
  final t = normalizeUtterance(utterance);
  if (t.isEmpty) return Command(VoiceIntent.unknown, raw);

  // Short confirmations first.
  if (RegExp(r'^(yes|yeah|yep|sure|correct|right|confirm|do it|go ahead)$').hasMatch(t)) {
    return Command(VoiceIntent.yes, raw);
  }
  if (RegExp(r'^(no|nope|dont|cancel|never mind|nevermind)$').hasMatch(t)) {
    return Command(VoiceIntent.no, raw);
  }

  // Emergency has the highest priority.
  if (_has(t, ['emergency', 'sos', 'help me', 'i need help', 'i am in danger', 'call for help'])) {
    if (_has(t, ['info', 'information', 'medical', 'details'])) {
      return Command(VoiceIntent.medicalInfo, raw);
    }
    return Command(VoiceIntent.emergency, raw);
  }
  if (_has(t, ['medical info', 'medical information', 'my medical', 'blood group', 'allergies'])) {
    return Command(VoiceIntent.medicalInfo, raw);
  }

  // Calls: "call ahmed", "dial mom", "phone sara".
  final callee = _after(t, ['call', 'dial', 'phone', 'ring']);
  if (callee != null && !_has(t, ['log', 'history'])) {
    return Command(VoiceIntent.call, raw, callee);
  }

  // Navigation and places.
  if (_has(t, ['stop navigation', 'stop guiding', 'cancel navigation', 'stop route', 'stop recording'])) {
    return Command(VoiceIntent.stopNavigation, raw);
  }
  if (_has(t, ['where am i', 'which room', 'what room', 'what place', 'my location'])) {
    return Command(VoiceIntent.whereAmI, raw);
  }
  final landmark = _after(t, [
    'save this place as',
    'save place as',
    'mark this place as',
    'save landmark',
    'this place is',
    'remember this place as',
    'save this location as'
  ]);
  if (landmark != null) return Command(VoiceIntent.saveLandmark, raw, landmark);
  if (_has(t, ['save this place', 'save place', 'save landmark', 'mark this place', 'remember this place'])) {
    return Command(VoiceIntent.saveLandmark, raw);
  }
  final recordTo =
      _after(t, ['record route to', 'record a route to', 'record path to', 'record the way to', 'record route']);
  if (recordTo != null) return Command(VoiceIntent.recordRoute, raw, recordTo);
  if (_has(t, ['record route', 'record path', 'record a route', 'record the way'])) {
    return Command(VoiceIntent.recordRoute, raw);
  }
  final dest =
      _after(t, ['take me to', 'guide me to', 'navigate to', 'how do i get to', 'go to', 'directions to', 'way to']);
  if (dest != null) return Command(VoiceIntent.navigateTo, raw, dest);

  // Saved objects.
  final whereLast =
      _after(t, ['where did i leave', 'where did i put', 'where did i last see', 'when did i last see', 'last seen']);
  if (whereLast != null) return Command(VoiceIntent.whereLast, raw, whereLast);
  final saveObj = _after(t, [
    'save this object as',
    'save this as',
    'remember this as',
    'save object as',
    'this is my',
    'remember my',
    'save my'
  ]);
  if (saveObj != null && !_has(t, ['person', 'face', 'place', 'landmark'])) {
    return Command(VoiceIntent.saveObject, raw, saveObj);
  }
  if (_has(t, ['save this object', 'save object', 'remember this object', 'add object'])) {
    return Command(VoiceIntent.saveObject, raw);
  }
  final findObj = _after(t, [
    'find my',
    'find the',
    'find',
    'look for',
    'search for',
    'where is my',
    'where are my',
    'where is the',
    'locate'
  ]);
  if (findObj != null) return Command(VoiceIntent.findObject, raw, findObj);

  // People.
  final personName = _after(t, [
    'save this person as',
    'save person as',
    'this person is',
    'remember this person as',
    'save face as',
    'this is'
  ]);
  if (personName != null && _has(t, ['person', 'face', 'this is'])) {
    return Command(VoiceIntent.savePerson, raw, personName);
  }
  if (_has(
      t, ['save person', 'save this person', 'remember this person', 'save face', 'add person', 'remember face'])) {
    return Command(VoiceIntent.savePerson, raw);
  }
  if (_has(t, [
    'who is here',
    'who is this',
    'who is in front',
    'who is around',
    'whos here',
    'whos this',
    'recognize',
    'any people',
    'anyone here',
    'who is that'
  ])) {
    return Command(VoiceIntent.whoIsHere, raw);
  }
  if (_has(t,
      ['list saved', 'what have i saved', 'saved items', 'list objects', 'list people', 'list places', 'my saved'])) {
    return Command(VoiceIntent.listSaved, raw);
  }

  // Reading, money, colors.
  if (_has(t, ['read', 'text', 'what does it say', 'what does this say', 'document', 'letter', 'label'])) {
    return Command(VoiceIntent.readText, raw);
  }
  if (_has(t, ['money', 'currency', 'rupees', 'rupee', 'note', 'notes', 'cash', 'how much'])) {
    return Command(VoiceIntent.currency, raw);
  }
  if (_has(
      t, ['does this match', 'do these match', 'match', 'go together', 'goes with', 'compare clothes', 'compare'])) {
    return Command(VoiceIntent.matchClothes, raw);
  }
  if (_has(t, ['clothes', 'clothing', 'shirt', 'outfit', 'dress', 'trousers', 'pants', 'jacket', 'wearing'])) {
    return Command(VoiceIntent.clothing, raw);
  }
  if (_has(t, ['light', 'lights', 'how bright', 'is it dark', 'brightness'])) {
    return Command(VoiceIntent.lightLevel, raw);
  }
  if (_has(t, ['color', 'colour', 'what color', 'which color'])) {
    return Command(VoiceIntent.color, raw);
  }

  // Seeing.
  if (_has(
      t, ['describe', 'scene', 'what do you see', 'where is this', 'surroundings', 'look around', 'what is around'])) {
    return Command(VoiceIntent.describeScene, raw);
  }
  if (_has(t, ['obstacle', 'obstacles', 'walking mode', 'walk mode', 'guide my walk', 'is the path clear', 'path'])) {
    return Command(VoiceIntent.obstacles, raw);
  }
  if (_has(t, [
    'what is in front',
    'whats in front',
    'in front of me',
    'what is this',
    'whats this',
    'identify',
    'objects',
    'what is ahead',
    'whats ahead'
  ])) {
    return Command(VoiceIntent.whatsAhead, raw);
  }

  // Logs.
  if (_has(t, ['clear log', 'clear history', 'delete history', 'delete log', 'clear activity'])) {
    return Command(VoiceIntent.clearLog, raw);
  }
  if (_has(t, ['what did i do', 'activity', 'history', 'log', 'todays summary', 'summary', 'recent'])) {
    return Command(VoiceIntent.activityToday, raw);
  }

  // Utility.
  if (_has(t, ['time', 'what time', 'clock'])) return Command(VoiceIntent.time, raw);
  if (_has(t, ['date', 'what day', 'todays date', 'which day'])) return Command(VoiceIntent.date, raw);
  if (_has(t, ['repeat', 'say again', 'say that again', 'what did you say', 'pardon'])) {
    return Command(VoiceIntent.repeat, raw);
  }
  if (_has(t, ['faster', 'speak faster', 'speed up'])) return Command(VoiceIntent.faster, raw);
  if (_has(t, ['slower', 'speak slower', 'slow down'])) return Command(VoiceIntent.slower, raw);
  if (_has(t, ['brief', 'less talk', 'shorter', 'quiet mode', 'less detail'])) return Command(VoiceIntent.brief, raw);
  if (_has(t, ['verbose', 'more detail', 'more talk', 'detailed'])) return Command(VoiceIntent.verbose, raw);
  if (_has(t, ['help', 'what can you do', 'commands', 'how do i', 'instructions', 'tutorial'])) {
    return Command(VoiceIntent.help, raw);
  }
  if (_has(t, ['stop', 'quiet', 'silence', 'shut up', 'pause'])) return Command(VoiceIntent.stop, raw);
  if (_has(t, ['cancel', 'never mind', 'nevermind'])) return Command(VoiceIntent.cancel, raw);

  // "open text mode", "go to currency", or just a mode name.
  for (final e in modeAliases.entries) {
    if (_has(t, e.value)) return Command(VoiceIntent.openMode, raw, e.key);
  }
  return Command(VoiceIntent.unknown, raw);
}

/// Picks the best fuzzy match for [spoken] among [names] (case-insensitive),
/// or null. Used for object, person and place names.
String? matchName(String spoken, Iterable<String> names) {
  final q = normalizeUtterance(spoken).replaceFirst(RegExp(r'^(my|the|a|an) '), '');
  String? best;
  double bestScore = 0;
  for (final n in names) {
    final c = n.toLowerCase().trim();
    double score;
    if (c == q) {
      score = 1;
    } else if (c.contains(q) || q.contains(c)) {
      score = 0.85;
    } else {
      final d = _levenshtein(q, c);
      score = 1 - d / (q.length > c.length ? q.length : c.length);
      // Plural/singular forgiveness.
      if (q.replaceAll(RegExp(r's$'), '') == c.replaceAll(RegExp(r's$'), '')) score = 0.95;
    }
    if (score > bestScore) {
      bestScore = score;
      best = n;
    }
  }
  return bestScore >= 0.6 ? best : null;
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (int i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (int j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}
