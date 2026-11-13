import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/consent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ConsentService (Ticket C-3)', () {
    test('default is refusal: no record means no sync', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ConsentService();
      final record = await service.get('PAT-1');
      expect(record, isNull);
    });

    test('grant records versioned consent that allows sync', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ConsentService();

      final record = await service.grant('PAT-1', language: 'hi');

      expect(record.isSyncAllowed, isTrue);
      expect(record.version, ConsentService.consentVersion);
      final stored = await service.get('PAT-1');
      expect(stored!.isSyncAllowed, isTrue);
      expect(stored.language, 'hi');
    });

    test('refuse stores the decision but never allows sync', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ConsentService();

      await service.refuse('PAT-2');

      final stored = await service.get('PAT-2');
      expect(stored!.granted, isFalse);
      expect(stored.isSyncAllowed, isFalse);
    });

    test('withdrawal flips sync off immediately (DPDP S.6(4))', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ConsentService();

      await service.grant('PAT-3');
      expect((await service.get('PAT-3'))!.isSyncAllowed, isTrue);

      await service.withdraw('PAT-3');
      final after = await service.get('PAT-3');
      expect(after!.granted, isFalse);
      expect(after.withdrawnAt, isNotNull);
      expect(after.isSyncAllowed, isFalse);
    });

    test(
      'records are per-patient (one grant never leaks to another)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final service = ConsentService();

        await service.grant('PAT-A');
        final other = await service.get('PAT-B');

        expect(other, isNull);
      },
    );
  });
}
