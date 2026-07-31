import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

class MatchedContact {
  final String displayName;
  final String phoneNumber;
  final int confidenceScore;

  MatchedContact({
    required this.displayName,
    required this.phoneNumber,
    required this.confidenceScore,
  });
}

/// Service that manages device contacts, provides intelligent fuzzy matching
/// for spoken names, and offers phone-number reverse lookup for incoming calls.
class ContactsService {
  ContactsService._internal();
  static final ContactsService instance = ContactsService._internal();

  List<Contact> _cache = [];

  /// Returns true if contact permission is granted.
  Future<bool> hasPermission() async {
    return await Permission.contacts.isGranted;
  }

  /// Requests permission to read device contacts.
  Future<bool> ensurePermission() async {
    final status = await Permission.contacts.request();
    return status.isGranted;
  }

  /// Loads device contacts into memory.
  Future<void> loadContacts() async {
    try {
      if (!await hasPermission()) {
        final granted = await ensurePermission();
        if (!granted) return;
      }
      _cache = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
    } catch (e) {
      _cache = [];
    }
  }

  /// Sets contacts manually (useful for testing or external overrides).
  void setContactsForTesting(List<Contact> contacts) {
    _cache = contacts;
  }

  /// Dynamically re-syncs device contacts and returns the best-matching contact for spoken name.
  Future<MatchedContact?> findBestMatchAsync(String spokenName, {int minConfidenceScore = 55}) async {
    await loadContacts();
    return findBestMatch(spokenName, minConfidenceScore: minConfidenceScore);
  }

  /// Looks up a contact by phone number, normalizing formats and country codes.
  Future<Contact?> findContactByNumberAsync(String incomingNumber) async {
    await loadContacts();
    return findContactByNumber(incomingNumber);
  }

  /// Reverse lookup contact by phone number against cached contacts.
  Contact? findContactByNumber(String incomingNumber) {
    final rawIncoming = normalizePhoneNumber(incomingNumber);
    if (rawIncoming.isEmpty || _cache.isEmpty) return null;

    for (final contact in _cache) {
      for (final phone in contact.phones) {
        final rawPhone = normalizePhoneNumber(phone.number);
        if (rawPhone.isEmpty) continue;

        // Check exact match or suffix match (last 7-10 digits) to handle +country codes
        if (rawIncoming == rawPhone) return contact;

        if (rawIncoming.length >= 7 && rawPhone.length >= 7) {
          final incomingTail = rawIncoming.substring(rawIncoming.length - 7);
          final phoneTail = rawPhone.substring(rawPhone.length - 7);
          if (incomingTail == phoneTail) {
            return contact;
          }
        }
      }
    }
    return null;
  }

  /// Returns the best-matching contact for [spokenName], or null if no
  /// candidate cleared the minimum confidence threshold ([minConfidenceScore]).
  MatchedContact? findBestMatch(String spokenName, {int minConfidenceScore = 55}) {
    final query = normalizeString(spokenName);
    if (query.isEmpty || _cache.isEmpty) return null;

    Contact? bestContact;
    int maxScore = -1;

    for (final c in _cache) {
      if (c.phones.isEmpty) continue;
      final contactName = normalizeString(c.displayName);
      if (contactName.isEmpty) continue;

      final score = calculateSimilarityScore(query, contactName);
      if (score > maxScore) {
        maxScore = score;
        bestContact = c;
      }
    }

    if (bestContact == null || maxScore < minConfidenceScore) {
      return null;
    }

    // Select primary or first phone number
    final phone = _selectBestPhone(bestContact.phones);
    return MatchedContact(
      displayName: bestContact.displayName,
      phoneNumber: phone,
      confidenceScore: maxScore,
    );
  }

  String _selectBestPhone(List<Phone> phones) {
    if (phones.isEmpty) return '';
    // Prefer mobile if available
    for (final p in phones) {
      if (p.label == PhoneLabel.mobile || p.number.replaceAll(RegExp(r'\D'), '').length >= 7) {
        return p.number;
      }
    }
    return phones.first.number;
  }

  /// Strips all non-digit characters from a phone number string for clean matching.
  static String normalizePhoneNumber(String number) {
    return number.replaceAll(RegExp(r'\D'), '');
  }

  /// Normalizes spoken or stored contact strings by converting to lowercase,
  /// replacing common diacritics/accents, and stripping special characters.
  static String normalizeString(String input) {
    String s = input.toLowerCase().trim();
    // Common diacritic replacements
    s = s
        .replaceAll(RegExp(r'[àáâãäå]'), 'a')
        .replaceAll(RegExp(r'[èéêë]'), 'e')
        .replaceAll(RegExp(r'[ìíîï]'), 'i')
        .replaceAll(RegExp(r'[òóôõö]'), 'o')
        .replaceAll(RegExp(r'[ùúûü]'), 'u')
        .replaceAll(RegExp(r'[ñ]'), 'n');
    
    // Expand common spoken aliases
    if (s == 'mom' || s == 'mother' || s == 'mommy') s = 'mom';
    if (s == 'dad' || s == 'father' || s == 'daddy') s = 'dad';

    // Keep letters and digits, convert punctuation to spaces
    return s.replaceAll(RegExp(r'[^a-z0-9]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Calculates a similarity score (0 to 100) between [query] and [candidate].
  static int calculateSimilarityScore(String query, String candidate) {
    if (query.isEmpty || candidate.isEmpty) return 0;
    if (query == candidate) return 100;

    // Direct substring bonus
    if (candidate.contains(query) || query.contains(candidate)) {
      final ratio = query.length / candidate.length;
      if (ratio > 0.6) return 92;
      return 85;
    }

    final qTokens = query.split(' ');
    final cTokens = candidate.split(' ');

    // Check token-level exact overlap
    final qSet = qTokens.toSet();
    final cSet = cTokens.toSet();
    final exactOverlap = qSet.intersection(cSet);
    if (exactOverlap.isNotEmpty) {
      final overlapRatio = exactOverlap.length / qTokens.length;
      final score = (overlapRatio * 85).round();
      if (score >= 80) return score;
    }

    // Token-wise Levenshtein matching
    double totalTokenScore = 0;
    for (final qToken in qTokens) {
      double maxTokenScore = 0;
      for (final cToken in cTokens) {
        final dist = damerauLevenshteinDistance(qToken, cToken);
        final maxLen = qToken.length > cToken.length ? qToken.length : cToken.length;
        if (maxLen == 0) continue;
        final tokenSim = 1.0 - (dist / maxLen);
        if (tokenSim > maxTokenScore) {
          maxTokenScore = tokenSim;
        }
      }
      totalTokenScore += maxTokenScore;
    }

    final avgTokenSim = totalTokenScore / qTokens.length;
    final levenshteinScore = (avgTokenSim * 100).round();

    // Global string Levenshtein fallback
    final globalDist = damerauLevenshteinDistance(query, candidate);
    final maxGlobalLen = query.length > candidate.length ? query.length : candidate.length;
    final globalSim = 1.0 - (globalDist / maxGlobalLen);
    final globalScore = (globalSim * 100).round();

    final finalScore = levenshteinScore > globalScore ? levenshteinScore : globalScore;
    return finalScore < 0 ? 0 : (finalScore > 100 ? 100 : finalScore);
  }

  /// Calculates Damerau-Levenshtein distance between two strings.
  static int damerauLevenshteinDistance(String source, String target) {
    if (source == target) return 0;
    if (source.isEmpty) return target.length;
    if (target.isEmpty) return source.length;

    final srcLen = source.length;
    final tgtLen = target.length;

    final matrix = List.generate(
      srcLen + 1,
      (_) => List<int>.filled(tgtLen + 1, 0),
    );

    for (int i = 0; i <= srcLen; i++) {
      matrix[i][0] = i;
    }
    for (int j = 0; j <= tgtLen; j++) {
      matrix[0][j] = j;
    }

    for (int i = 1; i <= srcLen; i++) {
      for (int j = 1; j <= tgtLen; j++) {
        final cost = (source[i - 1] == target[j - 1]) ? 0 : 1;
        int minDistance = matrix[i - 1][j] + 1; // deletion
        final insertion = matrix[i][j - 1] + 1;
        if (insertion < minDistance) minDistance = insertion;
        final substitution = matrix[i - 1][j - 1] + cost;
        if (substitution < minDistance) minDistance = substitution;

        // Damerau transposition
        if (i > 1 &&
            j > 1 &&
            source[i - 1] == target[j - 2] &&
            source[i - 2] == target[j - 1]) {
          final transposition = matrix[i - 2][j - 2] + cost;
          if (transposition < minDistance) minDistance = transposition;
        }

        matrix[i][j] = minDistance;
      }
    }

    return matrix[srcLen][tgtLen];
  }
}
