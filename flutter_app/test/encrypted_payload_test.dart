import 'package:flutter_test/flutter_test.dart';

import 'package:drishti/services/security/encrypted_payload.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptedPayload', () {
    test('AES-GCM round-trips JSON containing PHI-shaped data', () async {
      const plain = '{"name":"Ramesh Patil","phone":"9822058112","grade":2}';
      final encrypted = await EncryptedPayload.encrypt(plain);
      expect(EncryptedPayload.isEncrypted(encrypted), isTrue);
      expect(encrypted.contains('Ramesh'), isFalse);
      expect(encrypted.contains('9822058112'), isFalse);
      expect(await EncryptedPayload.decrypt(encrypted), plain);
    });

    test('tampered ciphertext is rejected, never silently accepted', () async {
      final encrypted = await EncryptedPayload.encrypt('{"grade":2}');
      final tampered = '${encrypted.substring(0, encrypted.length - 4)}AAAA';
      expect(await EncryptedPayload.decrypt(tampered), isNull);
    });

    test('legacy plaintext is returned for one-time migration', () async {
      const legacy = '[{"name":"Legacy Patient"}]';
      expect(await EncryptedPayload.readOrLegacy(legacy), legacy);
    });

    test('ciphertext is non-deterministic (fresh nonce per write)', () async {
      final a = await EncryptedPayload.encrypt('same');
      final b = await EncryptedPayload.encrypt('same');
      expect(a, isNot(b));
      expect(await EncryptedPayload.decrypt(a), 'same');
      expect(await EncryptedPayload.decrypt(b), 'same');
    });
  });
}
