import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 8, 28, 8);

  setUp(resetAppProviderContainerForTest);
  tearDown(resetAppProviderContainerForTest);

  test(
    'normal build defaults only memory and natural conversation to enforce',
    () {
      final maxima = MaasoFeatureFlagService.parseCompileMaximums('');
      for (final flag in MaasoFeatureFlag.values) {
        expect(
          maxima[flag],
          flag == MaasoFeatureFlag.memoryV2 ||
                  flag == MaasoFeatureFlag.naturalConversation
              ? FeatureRolloutMode.enforce
              : FeatureRolloutMode.off,
          reason: flag.key,
        );
      }
      for (final source in const [
        'memory_v2:off',
        'memory_v2:invalid',
        'memory_v2',
        'memory_v2=off',
        'memory_v2:off:enforce',
        'memory_v2:off,memory_v2:enforce',
        'memory_v2:enforce,memory_v2:invalid',
      ]) {
        expect(
          MaasoFeatureFlagService.parseCompileMaximums(
            source,
          )[MaasoFeatureFlag.memoryV2],
          FeatureRolloutMode.off,
          reason: source,
        );
      }
      expect(
        MaasoFeatureFlagService.parseCompileMaximums(
          'memory_v2:shadow,memory_v2:enforce',
        )[MaasoFeatureFlag.memoryV2],
        FeatureRolloutMode.shadow,
      );
    },
  );

  test(
    'healthy never-configured account gets memory and natural conversation',
    () async {
      final service = MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        clock: () => now,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      await service.init();
      expect(
        service.state.value,
        isEmpty,
        reason: 'No synthetic assignment is written.',
      );
      for (final flag in MaasoFeatureFlag.values) {
        expect(
          service.effectiveMode(flag),
          flag == MaasoFeatureFlag.memoryV2 ||
                  flag == MaasoFeatureFlag.naturalConversation
              ? FeatureRolloutMode.enforce
              : FeatureRolloutMode.off,
          reason: flag.key,
        );
      }
      final generation = service.authorityGeneration(MaasoFeatureFlag.memoryV2);
      service.setRuntimeMaximum(
        MaasoFeatureFlag.memoryV2,
        FeatureRolloutMode.off,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      expect(
        service.authorityGeneration(MaasoFeatureFlag.memoryV2),
        greaterThan(generation),
      );
      service.setRuntimeMaximum(
        MaasoFeatureFlag.memoryV2,
        FeatureRolloutMode.enforce,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.enforce,
      );
      service.disableAll();
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      await service.deactivateAndDrain();
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
    },
  );

  test(
    'natural conversation explicit and malformed build caps stay bounded',
    () {
      for (final source in const [
        'natural_conversation:off',
        'natural_conversation:invalid',
        'natural_conversation',
        'natural_conversation=off',
        'natural_conversation:off:enforce',
        'natural_conversation:off,natural_conversation:enforce',
        'natural_conversation:enforce,natural_conversation:invalid',
      ]) {
        final maxima = MaasoFeatureFlagService.parseCompileMaximums(source);
        expect(
          maxima[MaasoFeatureFlag.naturalConversation],
          FeatureRolloutMode.off,
          reason: source,
        );
        expect(maxima[MaasoFeatureFlag.memoryV2], FeatureRolloutMode.enforce);
        expect(maxima[MaasoFeatureFlag.proactiveDrive], FeatureRolloutMode.off);
      }
      expect(
        MaasoFeatureFlagService.parseCompileMaximums(
          'natural_conversation:shadow,natural_conversation:enforce',
        )[MaasoFeatureFlag.naturalConversation],
        FeatureRolloutMode.shadow,
      );
    },
  );

  test(
    'unassigned conversation default obeys runtime kill and retirement',
    () async {
      final service = MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        clock: () => now,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.off,
      );
      await service.init();
      expect(service.state.value, isEmpty);
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.enforce,
      );
      service.setRuntimeMaximum(
        MaasoFeatureFlag.naturalConversation,
        FeatureRolloutMode.off,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.off,
      );
      service.setRuntimeMaximum(
        MaasoFeatureFlag.naturalConversation,
        FeatureRolloutMode.enforce,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.enforce,
      );
      service.disableAll();
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.off,
      );
      await service.deactivateAndDrain();
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.off,
      );
      expect(
        () => service.setRuntimeMaximum(
          MaasoFeatureFlag.naturalConversation,
          FeatureRolloutMode.enforce,
        ),
        throwsStateError,
      );
      service.closeLifecycle();
    },
  );

  test(
    'conversation build caps constrain assigned and unassigned accounts',
    () async {
      for (final mode in FeatureRolloutMode.values) {
        final service = await MaasoFeatureFlagService(
          store: _MemoryFeatureFlagStore(),
          compileMaximums: {MaasoFeatureFlag.naturalConversation: mode},
          clock: () => now,
        ).init();
        expect(
          service.effectiveMode(MaasoFeatureFlag.naturalConversation),
          mode,
        );
        await service.assign(
          flag: MaasoFeatureFlag.naturalConversation,
          mode: FeatureRolloutMode.enforce,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        );
        service.setRuntimeMaximum(
          MaasoFeatureFlag.naturalConversation,
          FeatureRolloutMode.enforce,
        );
        expect(
          service.effectiveMode(MaasoFeatureFlag.naturalConversation),
          mode,
        );
        service.closeLifecycle();
      }
    },
  );

  test(
    'conversation assignments and expiry never regain the absent default',
    () async {
      for (final mode in FeatureRolloutMode.values) {
        final store = _MemoryFeatureFlagStore();
        final service = await MaasoFeatureFlagService(
          store: store,
          clock: () => now,
        ).init();
        await service.assign(
          flag: MaasoFeatureFlag.naturalConversation,
          mode: mode,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        );
        expect(
          service.effectiveMode(MaasoFeatureFlag.naturalConversation),
          mode,
        );
        final restarted = await MaasoFeatureFlagService(
          store: store,
          clock: () => now,
        ).init();
        expect(
          restarted.effectiveMode(MaasoFeatureFlag.naturalConversation),
          mode,
        );
        expect(
          service.effectiveMode(
            MaasoFeatureFlag.naturalConversation,
            now: now.add(const Duration(hours: 2)),
          ),
          FeatureRolloutMode.off,
        );
        service.state.value = const {};
        expect(
          service.effectiveMode(MaasoFeatureFlag.naturalConversation),
          FeatureRolloutMode.off,
        );
        service.closeLifecycle();
        restarted.closeLifecycle();
      }
    },
  );

  test(
    'bad conversation cache or unidentified assignment suppresses default',
    () async {
      final valid = MaasoFeatureFlagAssignment(
        flag: MaasoFeatureFlag.naturalConversation,
        mode: FeatureRolloutMode.off,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      ).toJson();
      for (final row in <Map<String, Object?>>[
        {'flag': MaasoFeatureFlag.naturalConversation.key},
        {...valid, 'mode': 'invalid'},
        {...valid, 'expiresAt': 'not-a-date'},
        {'unexpected': true},
        {'flag': 'unknown', 'mode': 'off'},
      ]) {
        final service = await MaasoFeatureFlagService(
          store: _MemoryFeatureFlagStore(rows: [row]),
          clock: () => now,
        ).init();
        expect(
          service.effectiveMode(MaasoFeatureFlag.naturalConversation),
          FeatureRolloutMode.off,
          reason: '$row',
        );
        service.closeLifecycle();
      }
      final service = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore()..failReads = true,
        clock: () => now,
      ).init();
      expect(
        service.effectiveMode(MaasoFeatureFlag.naturalConversation),
        FeatureRolloutMode.off,
      );
      service.closeLifecycle();
    },
  );

  test(
    'explicit memory build caps constrain the unconfigured default',
    () async {
      for (final mode in FeatureRolloutMode.values) {
        final service = await MaasoFeatureFlagService(
          store: _MemoryFeatureFlagStore(),
          compileMaximums: {MaasoFeatureFlag.memoryV2: mode},
          clock: () => now,
        ).init();
        expect(service.effectiveMode(MaasoFeatureFlag.memoryV2), mode);
        service.setRuntimeMaximum(
          MaasoFeatureFlag.memoryV2,
          FeatureRolloutMode.enforce,
        );
        expect(service.effectiveMode(MaasoFeatureFlag.memoryV2), mode);
        service.closeLifecycle();
      }
    },
  );

  test(
    'explicit account modes and expiry never inherit the memory default',
    () async {
      for (final mode in FeatureRolloutMode.values) {
        final store = _MemoryFeatureFlagStore();
        final service = await MaasoFeatureFlagService(
          store: store,
          clock: () => now,
        ).init();
        await service.assign(
          flag: MaasoFeatureFlag.memoryV2,
          mode: mode,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        );
        expect(service.effectiveMode(MaasoFeatureFlag.memoryV2), mode);
        expect(
          service.effectiveMode(
            MaasoFeatureFlag.memoryV2,
            now: now.add(const Duration(hours: 2)),
          ),
          FeatureRolloutMode.off,
        );
        final restarted = await MaasoFeatureFlagService(
          store: store,
          clock: () => now,
        ).init();
        expect(restarted.effectiveMode(MaasoFeatureFlag.memoryV2), mode);
        service.state.value = const {};
        expect(
          service.effectiveMode(MaasoFeatureFlag.memoryV2),
          FeatureRolloutMode.off,
        );
        service.closeLifecycle();
        restarted.closeLifecycle();
      }
    },
  );

  test('corrupt explicit memory rows suppress the local default', () async {
    final valid = MaasoFeatureFlagAssignment(
      flag: MaasoFeatureFlag.memoryV2,
      mode: FeatureRolloutMode.off,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    ).toJson();
    for (final row in <Map<String, Object?>>[
      {'flag': MaasoFeatureFlag.memoryV2.key},
      {...valid, 'mode': 'invalid'},
      {...valid, 'revision': 0},
      {...valid, 'expiresAt': 'not-a-date'},
      {...valid, 'unexpected': true},
    ]) {
      final service = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(rows: [row]),
        clock: () => now,
      ).init();
      expect(service.state.value, isEmpty);
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      service.closeLifecycle();
    }
  });

  test(
    'unidentified cache rows cannot be treated as never configured',
    () async {
      for (final row in <Map<String, Object?>>[
        {'unexpected': true},
        {'flag': 'unknown', 'mode': 'off'},
      ]) {
        final store = _MemoryFeatureFlagStore(rows: [row]);
        final service = await MaasoFeatureFlagService(
          store: store,
          clock: () => now,
        ).init();
        expect(
          service.effectiveMode(MaasoFeatureFlag.memoryV2),
          FeatureRolloutMode.off,
        );
        await service.assign(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.shadow,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        );
        expect(
          service.effectiveMode(MaasoFeatureFlag.memoryV2),
          FeatureRolloutMode.shadow,
        );
        service.closeLifecycle();
      }
    },
  );

  test(
    'default governance stays off until a healthy assignment read completes',
    () async {
      final readGate = Completer<void>();
      final service = MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore()..readGate = readGate.future,
        clock: () => now,
      );
      final initialization = service.init();
      await Future<void>.delayed(Duration.zero);
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      readGate.complete();
      await initialization;
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.enforce,
      );
      service.closeLifecycle();
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      final degraded = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore()..failReads = true,
        clock: () => now,
      ).init();
      expect(
        degraded.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
    },
  );

  test('compile maxima parser is complete and fail closed', () {
    final parsed = MaasoFeatureFlagService.parseCompileMaximums(
      'proactive_drive:shadow,memory_v2:enforce,unknown:enforce,'
      'voice_prosody:invalid',
    );

    expect(parsed, hasLength(MaasoFeatureFlag.values.length));
    expect(parsed[MaasoFeatureFlag.proactiveDrive], FeatureRolloutMode.shadow);
    expect(parsed[MaasoFeatureFlag.memoryV2], FeatureRolloutMode.enforce);
    expect(parsed[MaasoFeatureFlag.voiceProsody], FeatureRolloutMode.off);
    expect(parsed[MaasoFeatureFlag.actionContractV2], FeatureRolloutMode.off);
  });

  test(
    'missing assignment remains off even when the build allows shadow',
    () async {
      final service = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();

      expect(
        service.effectiveMode(MaasoFeatureFlag.proactiveDrive),
        FeatureRolloutMode.off,
      );
    },
  );

  test(
    'persisted proactive enforce assignment respects build and runtime caps',
    () async {
      final store = _MemoryFeatureFlagStore();
      final first = await MaasoFeatureFlagService(
        store: store,
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();
      await first.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );

      expect(
        first.effectiveMode(MaasoFeatureFlag.proactiveDrive),
        FeatureRolloutMode.enforce,
      );

      final restored = await MaasoFeatureFlagService(
        store: store,
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();
      expect(
        restored.effectiveMode(MaasoFeatureFlag.proactiveDrive),
        FeatureRolloutMode.shadow,
      );
    },
  );

  test('expired and invalid cache rows fail closed', () async {
    final store = _MemoryFeatureFlagStore(
      rows: <Map<String, Object?>>[
        <String, Object?>{'unexpected': true},
        MaasoFeatureFlagAssignment(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.enforce,
          revision: 1,
          expiresAt: now.subtract(const Duration(seconds: 1)),
        ).toJson(),
      ],
    );
    final service = await MaasoFeatureFlagService(
      store: store,
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();

    expect(
      service.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
  });

  test(
    'cache read failure does not block init and remains read-only off',
    () async {
      final store = _MemoryFeatureFlagStore()..failReads = true;
      final service = await MaasoFeatureFlagService(
        store: store,
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();

      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      await expectLater(
        service.assign(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.enforce,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        ),
        throwsStateError,
      );
    },
  );

  test('concurrent init cannot bypass an in-flight retirement fence', () async {
    final readGate = Completer<void>();
    final store = _MemoryFeatureFlagStore()..readGate = readGate.future;
    final service = MaasoFeatureFlagService(
      store: store,
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    );

    final initialization = service.init();
    await Future<void>.delayed(Duration.zero);
    await expectLater(service.init(), throwsStateError);
    final drain = service.deactivateAndDrain();
    readGate.complete();

    expect(await initialization, same(service));
    await drain;
    expect(
      service.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
    await expectLater(service.init(), throwsStateError);
    expect(
      () => service.setRuntimeMaximum(
        MaasoFeatureFlag.memoryV2,
        FeatureRolloutMode.enforce,
      ),
      throwsStateError,
    );
  });

  test('close during cache read cannot republish restored state', () async {
    final readGate = Completer<void>();
    final store = _MemoryFeatureFlagStore(
      rows: <Map<String, Object?>>[
        MaasoFeatureFlagAssignment(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.enforce,
          revision: 1,
          expiresAt: now.add(const Duration(hours: 1)),
        ).toJson(),
      ],
    )..readGate = readGate.future;
    final service = MaasoFeatureFlagService(
      store: store,
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    );

    final initialization = service.init();
    await Future<void>.delayed(Duration.zero);
    service.closeLifecycle();
    readGate.complete();

    expect(await initialization, same(service));
    expect(service.state.value, isEmpty);
    expect(
      service.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
  });

  test(
    'reentrant retirement during state publication cannot reactivate',
    () async {
      final service = MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(
          rows: <Map<String, Object?>>[
            MaasoFeatureFlagAssignment(
              flag: MaasoFeatureFlag.memoryV2,
              mode: FeatureRolloutMode.enforce,
              revision: 1,
              expiresAt: now.add(const Duration(hours: 1)),
            ).toJson(),
          ],
        ),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      );
      var retired = false;
      final worker = service.state.listen((_) {
        if (retired) return;
        retired = true;
        service.deactivateAndDrain();
      });
      addTearDown(worker.dispose);

      await service.init();

      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      await expectLater(
        service.assign(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.enforce,
          revision: 2,
          expiresAt: now.add(const Duration(hours: 2)),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'runtime maximum is an immediate kill switch and cannot raise build cap',
    () async {
      final service = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.memoryV2: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();
      await service.assign(
        flag: MaasoFeatureFlag.memoryV2,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.shadow,
      );

      service.setRuntimeMaximum(
        MaasoFeatureFlag.memoryV2,
        FeatureRolloutMode.off,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      service.setRuntimeMaximum(
        MaasoFeatureFlag.memoryV2,
        FeatureRolloutMode.enforce,
      );
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.shadow,
      );
    },
  );

  test('authority generation revokes grants across runtime rollback', () async {
    final service = await MaasoFeatureFlagService(
      store: _MemoryFeatureFlagStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.companionActivity: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();
    final initialized = service.authorityGeneration(
      MaasoFeatureFlag.companionActivity,
    );
    await service.assign(
      flag: MaasoFeatureFlag.companionActivity,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final admitted = service.authorityGeneration(
      MaasoFeatureFlag.companionActivity,
    );

    service.setRuntimeMaximum(
      MaasoFeatureFlag.companionActivity,
      FeatureRolloutMode.off,
    );
    final rolledBack = service.authorityGeneration(
      MaasoFeatureFlag.companionActivity,
    );
    service.setRuntimeMaximum(
      MaasoFeatureFlag.companionActivity,
      FeatureRolloutMode.enforce,
    );
    final restored = service.authorityGeneration(
      MaasoFeatureFlag.companionActivity,
    );

    expect(initialized, greaterThan(0));
    expect(admitted, greaterThan(initialized));
    expect(rolledBack, greaterThan(admitted));
    expect(restored, greaterThan(rolledBack));
    expect(
      service.effectiveMode(MaasoFeatureFlag.companionActivity),
      FeatureRolloutMode.enforce,
    );
  });

  test('higher-revision off assignment survives service restart', () async {
    final store = _MemoryFeatureFlagStore();
    const maxima = <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
    };
    final first = await MaasoFeatureFlagService(
      store: store,
      compileMaximums: maxima,
      clock: () => now,
    ).init();
    await first.assign(
      flag: MaasoFeatureFlag.memoryV2,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    await first.assign(
      flag: MaasoFeatureFlag.memoryV2,
      mode: FeatureRolloutMode.off,
      revision: 2,
      expiresAt: now.add(const Duration(hours: 2)),
    );

    final restarted = await MaasoFeatureFlagService(
      store: store,
      compileMaximums: maxima,
      clock: () => now,
    ).init();

    expect(
      restarted.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
    expect(restarted.state.value[MaasoFeatureFlag.memoryV2]?.revision, 2);
    expect(store.writtenRevisions, <int>[1, 2]);
  });

  test('failed durable write never publishes the assignment', () async {
    final store = _MemoryFeatureFlagStore()..failWrites = true;
    final service = await MaasoFeatureFlagService(
      store: store,
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();

    await expectLater(
      service.assign(
        flag: MaasoFeatureFlag.memoryV2,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      ),
      throwsStateError,
    );
    expect(service.state.value, isEmpty);
  });

  test(
    'accepted writes drain in order and retirement rejects late writes',
    () async {
      final gate = Completer<void>();
      final store = _MemoryFeatureFlagStore()..writeGate = gate.future;
      final service = await MaasoFeatureFlagService(
        store: store,
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();

      final first = service.assign(
        flag: MaasoFeatureFlag.memoryV2,
        mode: FeatureRolloutMode.shadow,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      final second = service.assign(
        flag: MaasoFeatureFlag.memoryV2,
        mode: FeatureRolloutMode.enforce,
        revision: 2,
        expiresAt: now.add(const Duration(hours: 2)),
      );
      final drain = service.deactivateAndDrain();

      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
        reason: 'The account fence must fail closed before writes drain.',
      );

      await expectLater(
        service.assign(
          flag: MaasoFeatureFlag.memoryV2,
          mode: FeatureRolloutMode.off,
          revision: 3,
          expiresAt: now.add(const Duration(hours: 3)),
        ),
        throwsStateError,
      );
      gate.complete();
      await Future.wait<void>(<Future<void>>[first, second, drain]);

      expect(store.writtenRevisions, <int>[1, 2]);
      expect(service.state.value[MaasoFeatureFlag.memoryV2]?.revision, 2);
      expect(
        service.effectiveMode(MaasoFeatureFlag.memoryV2),
        FeatureRolloutMode.off,
      );
      expect(
        () => service.setRuntimeMaximum(
          MaasoFeatureFlag.memoryV2,
          FeatureRolloutMode.enforce,
        ),
        throwsStateError,
      );
      await expectLater(service.init(), throwsStateError);
    },
  );

  test('closed stale references always evaluate off', () async {
    final service = await MaasoFeatureFlagService(
      store: _MemoryFeatureFlagStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.memoryV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();
    await service.assign(
      flag: MaasoFeatureFlag.memoryV2,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );

    service.closeLifecycle();

    expect(
      service.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
    expect(service.state.value, isEmpty);
  });

  test('Sembast adapter persists per account database', () async {
    const accountAPath = 'feature-flags-account-a.db';
    const accountBPath = 'feature-flags-account-b.db';
    final accountA = await DBService().init(
      factory: databaseFactoryMemory,
      path: accountAPath,
    );
    final accountB = await DBService().init(
      factory: databaseFactoryMemory,
      path: accountBPath,
    );
    addTearDown(() async {
      await accountA.close();
      await accountB.close();
      await databaseFactoryMemory.deleteDatabase(accountAPath);
      await databaseFactoryMemory.deleteDatabase(accountBPath);
    });
    final firstA = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(accountA),
      clock: () => now,
    ).init();
    await firstA.assign(
      flag: MaasoFeatureFlag.memoryV2,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );

    final restoredA = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(accountA),
      clock: () => now,
    ).init();
    final unconfiguredB = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(accountB),
      clock: () => now,
    ).init();
    expect(
      unconfiguredB.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.enforce,
      reason: 'Account A shadow configuration does not leak into account B.',
    );
    await unconfiguredB.deactivateAndDrain();
    final mismatchedStore = StoreRef<String, Map<String, Object?>>(
      'feature_flag_assignments.v1',
    );
    await mismatchedStore
        .record(MaasoFeatureFlag.memoryV2.key)
        .put(
          accountB.raw,
          MaasoFeatureFlagAssignment(
            flag: MaasoFeatureFlag.actionContractV2,
            mode: FeatureRolloutMode.shadow,
            revision: 1,
            expiresAt: now.add(const Duration(hours: 1)),
          ).toJson(),
        );
    final freshB = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(accountB),
      clock: () => now,
    ).init();

    expect(
      restoredA.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.shadow,
    );
    expect(
      freshB.effectiveMode(MaasoFeatureFlag.memoryV2),
      FeatureRolloutMode.off,
    );
    expect(freshB.state.value, isEmpty);
    expect(
      (await mismatchedStore
          .record(MaasoFeatureFlag.memoryV2.key)
          .get(accountB.raw))?['flag'],
      MaasoFeatureFlag.actionContractV2.key,
      reason: 'Rejecting a corrupt row must not mutate its stored payload.',
    );
  });
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  _MemoryFeatureFlagStore({List<Map<String, Object?>> rows = const []})
    : _rows = rows.map(Map<String, Object?>.from).toList();

  final List<Map<String, Object?>> _rows;
  bool failReads = false;
  bool failWrites = false;
  Future<void>? readGate;
  Future<void>? writeGate;
  final List<int> writtenRevisions = <int>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async {
    await readGate;
    if (failReads) throw StateError('injected_read_failure');
    return _rows.map(Map<String, Object?>.from).toList(growable: false);
  }

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    await writeGate;
    if (failWrites) throw StateError('injected_write_failure');
    _rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    _rows.add(assignment.toJson());
    writtenRevisions.add(assignment.revision);
  }
}
