import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/data/companion_activity_store.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  test('Sembast final write fence rejects without persisting', () async {
    final database = await databaseFactoryMemory.openDatabase(
      'activity-final-fence.db',
    );
    final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 1);
    final store = SembastCompanionActivityStore(
      database: database,
      scope: scope,
    );

    await expectLater(
      store.transaction(
        (_) => CompanionActivityStoreMutation<int>(
          value: 1,
          document: <String, Object?>{
            'accountId': scope.accountId,
            'facadeGeneration': scope.facadeGeneration,
          },
          finalWriteFence: () => false,
        ),
      ),
      throwsStateError,
    );
    expect(await store.read(), isNull);
    await database.close();
  });

  test(
    'Sembast adapter persists and rehydrates account-generation state',
    () async {
      final database = await databaseFactoryMemory.openDatabase('activity.db');
      final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 4);
      final firstStore = SembastCompanionActivityStore(
        database: database,
        scope: scope,
      );
      final first = CompanionActivityService(
        store: firstStore,
        rolloutMode: () => FeatureRolloutMode.enforce,
      );
      final template = ActivityTaskTemplate(
        id: 'template-walk',
        scope: scope,
        title: 'Walk together',
        cadence: ActivityCadence.daily,
        defaultAwardPoints: 20,
      );
      final recurrence = ActivityRecurrenceRule(
        timeZoneId: 'Etc/UTC',
        offsetAtCreationMinutes: 0,
        localStartMinute: 8 * 60,
        firstLocalDate: ActivityLocalDate(2026, 8, 30),
      );

      expect(
        (await first.registerTemplate(
          operationId: 'template-1',
          template: template,
          recurrence: recurrence,
        )).status,
        CompanionActivityMutationStatus.applied,
      );
      expect(
        (await first.createOccurrence(
          operationId: 'occurrence-1',
          templateId: template.id,
          localDate: ActivityLocalDate(2026, 8, 30),
        )).status,
        CompanionActivityMutationStatus.applied,
      );

      final second = CompanionActivityService(
        store: SembastCompanionActivityStore(database: database, scope: scope),
        rolloutMode: () => FeatureRolloutMode.enforce,
      );
      final restored = await second.snapshot();
      expect(restored.templates.single.id, template.id);
      expect(restored.tasks.single.templateId, template.id);
      expect(restored.ledger.balance, 0);
      await database.close();
    },
  );

  test(
    'same account remount upgrades generation and cross-account fails closed',
    () async {
      final database = await databaseFactoryMemory.openDatabase('fence.db');
      final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 1);
      final store = SembastCompanionActivityStore(
        database: database,
        scope: scope,
      );
      await store.transaction(
        (_) => CompanionActivityStoreMutation<int>(
          value: 1,
          document: <String, Object?>{
            'schemaVersion': 1,
            'accountId': scope.accountId,
            'facadeGeneration': scope.facadeGeneration,
            'templates': <String, Object?>{},
            'tasks': <String, Object?>{},
            'evidence': <String, Object?>{},
            'ledgerOperations': <Object?>[],
            'receipts': <String, Object?>{},
          },
        ),
      );

      await store.deactivateAndDrain();

      final nextGeneration = SembastCompanionActivityStore(
        database: database,
        scope: ActivityScope(accountId: 'account-a', facadeGeneration: 2),
      );
      expect((await nextGeneration.read())!['facadeGeneration'], 1);
      await nextGeneration.transaction(
        (document) => CompanionActivityStoreMutation<int>(
          value: 2,
          document: <String, Object?>{
            ...document!,
            'schemaVersion': 2,
            'facadeGeneration': 2,
          },
        ),
      );
      expect((await nextGeneration.read())!['facadeGeneration'], 2);

      expect(store.read, throwsA(isA<StateError>()));
      expect(
        () => store.transaction<int>(
          (_) => const CompanionActivityStoreMutation<int>(
            value: 2,
            document: <String, Object?>{},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      final wrongAccount = SembastCompanionActivityStore(
        database: database,
        scope: ActivityScope(accountId: 'account-b', facadeGeneration: 3),
      );
      await expectLater(wrongAccount.read(), throwsA(isA<StateError>()));
      await database.close();
    },
  );

  test('gen1 drain then gen2 service restores durable activity data', () async {
    final database = await databaseFactoryMemory.openDatabase('remount.db');
    final scope1 = ActivityScope(accountId: 'account-a', facadeGeneration: 1);
    final store1 = SembastCompanionActivityStore(
      database: database,
      scope: scope1,
    );
    final service1 = CompanionActivityService(
      store: store1,
      rolloutMode: () => FeatureRolloutMode.enforce,
    );
    final template = ActivityTaskTemplate(
      id: 'template-walk',
      scope: scope1,
      title: 'Walk together',
      cadence: ActivityCadence.daily,
      defaultAwardPoints: 20,
    );
    await service1.registerTemplate(
      operationId: 'template-1',
      template: template,
      recurrence: ActivityRecurrenceRule(
        timeZoneId: 'Etc/UTC',
        offsetAtCreationMinutes: 0,
        localStartMinute: 8 * 60,
        firstLocalDate: ActivityLocalDate(2026, 8, 30),
      ),
    );
    await service1.createOccurrence(
      operationId: 'occurrence-1',
      templateId: template.id,
      localDate: ActivityLocalDate(2026, 8, 30),
    );
    await service1.deactivateAndDrain();

    final scope2 = ActivityScope(accountId: 'account-a', facadeGeneration: 2);
    final store2 = SembastCompanionActivityStore(
      database: database,
      scope: scope2,
    );
    final service2 = CompanionActivityService(
      store: store2,
      rolloutMode: () => FeatureRolloutMode.enforce,
    );
    final restored = await service2.snapshot();
    expect(restored.templates.single.id, template.id);
    expect(restored.templates.single.scope.facadeGeneration, 2);
    expect(restored.tasks.single.scope.facadeGeneration, 2);
    expect(
      (await service2.createOccurrence(
        operationId: 'occurrence-2',
        templateId: template.id,
        localDate: ActivityLocalDate(2026, 8, 31),
      )).status,
      CompanionActivityMutationStatus.applied,
    );
    expect((await store2.read())!['facadeGeneration'], 2);
    await service2.deactivateAndDrain();
    await database.close();
  });
}
