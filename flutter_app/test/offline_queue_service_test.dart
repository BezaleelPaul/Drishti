import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/offline_queue_service.dart';

void main() {
  group('OfflineQueueService (Ticket B-2)', () {
    test(
      'entries survive service re-creation on the same persistence',
      () async {
        final store = MemoryQueuePersistence();

        await OfflineQueueService.init(persistence: store);
        await OfflineQueueService.instance.addScreening({
          'local_screening_id': 'LOC-1',
          'patient_id': 'PAT-1',
          'image_base64': 'aGVsbG8=',
        });
        await OfflineQueueService.instance.addPatient({
          'patient_id': 'PAT-1',
          'name': 'Test Patient',
        });

        // Simulate an app restart: re-init against the SAME durable store.
        await OfflineQueueService.init(persistence: store);
        final restored = await OfflineQueueService.instance.restoreAll();

        expect(restored.screenings, hasLength(1));
        expect(restored.screenings.first.id, 'LOC-1');
        expect(restored.screenings.first.payload['patient_id'], 'PAT-1');
        expect(restored.patients, hasLength(1));
        expect(restored.patients.first.payload['name'], 'Test Patient');
      },
    );

    test('synced screenings are removed durably', () async {
      final store = MemoryQueuePersistence();
      await OfflineQueueService.init(persistence: store);

      await OfflineQueueService.instance.addScreening({
        'local_screening_id': 'LOC-1',
        'image_base64': 'aGk=',
      });
      await OfflineQueueService.instance.addScreening({
        'local_screening_id': 'LOC-2',
        'image_base64': 'aGk=',
      });

      // Server confirms LOC-1 only.
      await OfflineQueueService.instance.removeSyncedScreenings(['LOC-1']);

      final restored = await OfflineQueueService.instance.restoreAll();
      expect(restored.screenings.map((e) => e.id), ['LOC-2']);
    });

    test(
      'empty-id payloads are rejected (corrupt entries never persist)',
      () async {
        final store = MemoryQueuePersistence();
        await OfflineQueueService.init(persistence: store);

        await OfflineQueueService.instance.addScreening({
          'local_screening_id': '',
          'image_base64': 'x',
        });
        await OfflineQueueService.instance.addPatient({'patient_id': ''});

        final restored = await OfflineQueueService.instance.restoreAll();
        expect(restored.screenings, isEmpty);
        expect(restored.patients, isEmpty);
      },
    );

    test('memory-only mode reports isPersisted=false honestly', () async {
      await OfflineQueueService.init(persistence: MemoryQueuePersistence());
      expect(OfflineQueueService.instance.isPersisted, isFalse);
    });
  });
}
