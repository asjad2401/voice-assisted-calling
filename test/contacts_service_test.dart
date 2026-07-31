import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:blind_call_assistant/services/contacts_service.dart';

void main() {
  group('ContactsService - Normalization & Levenshtein Tests', () {
    test('String normalization removes diacritics, punctuation and converts to lower case', () {
      expect(ContactsService.normalizeString('José-María!'), equals('jose maria'));
      expect(ContactsService.normalizeString('   Möther   '), equals('mom'));
      expect(ContactsService.normalizeString('DAD!!'), equals('dad'));
      expect(ContactsService.normalizeString('Ahmed   Khan'), equals('ahmed khan'));
    });

    test('Damerau-Levenshtein distance calculation', () {
      expect(ContactsService.damerauLevenshteinDistance('ahmed', 'ahmed'), equals(0));
      expect(ContactsService.damerauLevenshteinDistance('ahmed', 'ahmedd'), equals(1)); // insertion
      expect(ContactsService.damerauLevenshteinDistance('ahmed', 'ahmd'), equals(1)); // deletion
      expect(ContactsService.damerauLevenshteinDistance('ahmed', 'ahmed'), equals(0));
      expect(ContactsService.damerauLevenshteinDistance('tehs', 'thes'), equals(1)); // transposition
    });

    test('Similarity score for exact and fuzzy matches', () {
      expect(ContactsService.calculateSimilarityScore('ahmed', 'ahmed'), equals(100));
      expect(ContactsService.calculateSimilarityScore('john', 'johnathan'), greaterThanOrEqualTo(85));
      expect(ContactsService.calculateSimilarityScore('mom', 'mom'), equals(100));
      expect(ContactsService.calculateSimilarityScore('xyz123', 'abc456'), lessThan(40));
    });
  });

  group('ContactsService - Find Best Match & Phone Reverse Lookup', () {
    final testContacts = [
      Contact(
        id: '1',
        displayName: 'Ahmed Khan',
        phones: [Phone('+92 300 1234567', label: PhoneLabel.mobile)],
      ),
      Contact(
        id: '2',
        displayName: 'Sarah Smith',
        phones: [Phone('0987654321', label: PhoneLabel.home)],
      ),
      Contact(
        id: '3',
        displayName: 'Mom',
        phones: [Phone('5551234567', label: PhoneLabel.mobile)],
      ),
    ];

    setUp(() {
      ContactsService.instance.setContactsForTesting(testContacts);
    });

    test('Finds exact match', () {
      final match = ContactsService.instance.findBestMatch('Ahmed Khan');
      expect(match, isNotNull);
      expect(match!.displayName, equals('Ahmed Khan'));
      expect(match.phoneNumber, equals('+92 300 1234567'));
      expect(match.confidenceScore, equals(100));
    });

    test('Finds match with minor typo / fuzzy name', () {
      final match = ContactsService.instance.findBestMatch('Ahmd Khan');
      expect(match, isNotNull);
      expect(match!.displayName, equals('Ahmed Khan'));
    });

    test('Finds match with spoken alias mom / mother', () {
      final match = ContactsService.instance.findBestMatch('mother');
      expect(match, isNotNull);
      expect(match!.displayName, equals('Mom'));
    });

    test('Returns null for completely unknown contact query', () {
      final match = ContactsService.instance.findBestMatch('Zubair Random Person XYZ');
      expect(match, isNull);
    });

    test('Reverse lookup finds contact by phone number even with country code variation', () {
      final contact = ContactsService.instance.findContactByNumber('03001234567');
      expect(contact, isNotNull);
      expect(contact!.displayName, equals('Ahmed Khan'));
    });
  });
}
