import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/models/result_status.dart';

/// Result-status vocabulary and pure derivation rules
/// (requirements 5.3, 6.1, 6.3, 6.4, 6.6, 8.5; design "Status state machine"
/// and the result_status module contract).
void main() {
  group('ScreeningResultStatus vocabulary', () {
    test('exposes the six specified status values', () {
      expect(ScreeningResultStatus.values.map((s) => s.name), <String>[
        'preliminary',
        'serviceConfirmed',
        'serviceDisagreed',
        'serviceProduced',
        'unavailable',
        'withheld',
      ]);
    });
  });

  group('deriveResultStatus', () {
    test('clean on-device grade is preliminary (6.1)', () {
      expect(deriveResultStatus(drGrade: 2), ScreeningResultStatus.preliminary);
    });

    test(
      'unreachable service (no confirmation recorded) leaves the result preliminary (6.4)',
      () {
        expect(
          deriveResultStatus(drGrade: 2, errorCode: null),
          ScreeningResultStatus.preliminary,
        );
      },
    );

    test('agreed confirmation is service-confirmed (6.3)', () {
      expect(
        deriveResultStatus(
          drGrade: 2,
          confirmation: ServiceConfirmation(agreed: true, serverGrade: 2),
        ),
        ScreeningResultStatus.serviceConfirmed,
      );
    });

    test('recorded disagreement is service-disagreed (6.6)', () {
      expect(
        deriveResultStatus(
          drGrade: 2,
          confirmation: ServiceConfirmation(agreed: false, serverGrade: 3),
        ),
        ScreeningResultStatus.serviceDisagreed,
      );
    });

    test('clean server result without a device result is service-produced', () {
      expect(
        deriveResultStatus(drGrade: 1, serverProduced: true),
        ScreeningResultStatus.serviceProduced,
      );
    });

    test('no grade produced anywhere is unavailable', () {
      expect(
        deriveResultStatus(drGrade: null),
        ScreeningResultStatus.unavailable,
      );
      expect(
        deriveResultStatus(drGrade: null, errorCode: 'AI_UNAVAILABLE'),
        ScreeningResultStatus.unavailable,
      );
      expect(
        deriveResultStatus(drGrade: null, serverProduced: true),
        ScreeningResultStatus.unavailable,
      );
      expect(
        deriveResultStatus(
          drGrade: null,
          errorCode: 'AI_TIMEOUT',
          serverProduced: true,
        ),
        ScreeningResultStatus.unavailable,
      );
    });

    test(
      'grade present with an availability/quality error code is withheld',
      () {
        expect(
          deriveResultStatus(drGrade: 2, errorCode: 'AI_LOW_CONFIDENCE'),
          ScreeningResultStatus.withheld,
        );
        expect(
          deriveResultStatus(drGrade: 2, errorCode: 'AI_TIMEOUT'),
          ScreeningResultStatus.withheld,
        );
        expect(
          deriveResultStatus(
            drGrade: 2,
            errorCode: 'AI_LOW_CONFIDENCE',
            serverProduced: true,
          ),
          ScreeningResultStatus.withheld,
        );
      },
    );

    test('quality/decode rejections derive to null — not a grading result', () {
      expect(
        deriveResultStatus(
          drGrade: null,
          errorCode: 'IMG_INVALID',
          serverProduced: true,
        ),
        isNull,
      );
      expect(
        deriveResultStatus(drGrade: null, errorCode: 'IMG_NOT_FUNDUS'),
        isNull,
      );
      expect(
        deriveResultStatus(drGrade: null, errorCode: 'IMG_UNGRADABLE'),
        isNull,
      );
    });

    test('quality/decode rejection outranks a recorded confirmation', () {
      expect(
        deriveResultStatus(
          drGrade: null,
          errorCode: 'IMG_UNGRADABLE',
          confirmation: ServiceConfirmation(agreed: true),
        ),
        isNull,
      );
    });

    test(
      'clean server result with an error code is withheld, not produced',
      () {
        expect(
          deriveResultStatus(
            drGrade: 1,
            errorCode: 'AI_LOW_CONFIDENCE',
            serverProduced: true,
          ),
          ScreeningResultStatus.withheld,
        );
      },
    );

    test('confirmation outranks the server-produced branch', () {
      expect(
        deriveResultStatus(
          drGrade: 1,
          serverProduced: true,
          confirmation: ServiceConfirmation(agreed: true),
        ),
        ScreeningResultStatus.serviceConfirmed,
      );
      expect(
        deriveResultStatus(
          drGrade: 1,
          serverProduced: true,
          confirmation: ServiceConfirmation(agreed: false, serverGrade: 2),
        ),
        ScreeningResultStatus.serviceDisagreed,
      );
    });
  });

  group('ScreeningResultStatus.tryParse', () {
    test('round-trips every status name', () {
      for (final status in ScreeningResultStatus.values) {
        expect(ScreeningResultStatus.tryParse(status.name), status);
      }
    });

    test('maps unknown or missing names to null (fail-safe)', () {
      expect(ScreeningResultStatus.tryParse(null), isNull);
      expect(ScreeningResultStatus.tryParse('unknown_status'), isNull);
    });
  });
}
