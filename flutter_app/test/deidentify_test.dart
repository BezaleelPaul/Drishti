import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/deidentify.dart';

void main() {
  group('DeidentificationService (Ticket C-2)', () {
    const deid = DeidentificationService(deviceSalt: 'test-salt-123');

    test('pseudonym is deterministic for the same patient + salt', () {
      final a = deid.pseudonym('PAT-001');
      final b = deid.pseudonym('PAT-001');
      expect(a, b);
    });

    test('pseudonym differs across patients and salts', () {
      final other = const DeidentificationService(deviceSalt: 'other-salt');
      expect(deid.pseudonym('PAT-001'), isNot(deid.pseudonym('PAT-002')));
      expect(deid.pseudonym('PAT-001'), isNot(other.pseudonym('PAT-001')));
    });

    test('pseudonym format: RSV- + 8 hex chars, no PHI leak', () {
      final p = deid.pseudonym('सुनीता बाई 9876543210');
      expect(p, matches(RegExp(r'^RSV-[0-9A-F]{8}$')));
      expect(p.contains('9876543210'), isFalse);
    });

    test('screening pseudonym differs from patient pseudonym', () {
      expect(
        deid.pseudonymizeScreening('LOC-123'),
        isNot(deid.pseudonym('LOC-123')),
      );
    });

    test('age bands coarse-grain to decades and reject nonsense', () {
      expect(deid.ageBand(43), '40-49');
      expect(deid.ageBand(44), '40-49');
      expect(deid.ageBand(70), '70-79');
      expect(deid.ageBand(null), isNull);
      expect(deid.ageBand(-5), isNull);
      expect(deid.ageBand(300), isNull);
    });

    test('deidentifyImage downscales and re-encodes (metadata stripped)', () {
      // 1024x512 red JPEG: the de-identified copy must be <=512 on the
      // longest side, still a valid JPEG, and NOT byte-identical to the
      // source (re-encode = all EXIF/GPS/serial metadata gone).
      final image = img.Image(width: 1024, height: 512);
      img.fill(image, color: img.ColorRgb8(180, 40, 40));
      final src = Uint8List.fromList(img.encodeJpg(image, quality: 95));

      final out = deid.deidentifyImage(src, maxDim: 512, quality: 80);

      expect(out[0], 0xFF); // JPEG SOI
      expect(out[1], 0xD8);
      expect(out.length, lessThan(src.length));
      final decoded = img.decodeImage(out);
      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(512));
      expect(decoded.height, lessThanOrEqualTo(512));
    });

    test('deidentifyImage rejects corrupt input (fail closed)', () {
      expect(
        () => deid.deidentifyImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });

    test('PHI linter: whitelist payload passes clean', () {
      final violations = deid.lintPayload({
        'pseudonym': 'RSV-AB12CD34',
        'pseudo_screening_id': 'SCR-AB12CD34',
        'age_band': '40-49',
        'gender': 'F',
        'eye_side': 'Right',
        'dr_grade': 2,
        'image_base64': 'xxxx',
        'consent_version': 'v1-2026-09',
      });
      expect(violations, isEmpty);
    });

    test('PHI linter fails closed on ANY extra or PHI field', () {
      expect(deid.lintPayload({'name': 'Sunita'}), contains('name'));
      expect(deid.lintPayload({'phone': '9876543210'}), contains('phone'));
      expect(
        deid.lintPayload({'abha_id': '12-3456-7890-1234'}),
        contains('abha_id'),
      );
      expect(deid.lintPayload({'village': 'Shirur'}), contains('village'));
      // Unknown field: not whitelisted -> violation.
      expect(deid.lintPayload({'notes': 'free text'}), contains('notes'));
    });
  });
}
