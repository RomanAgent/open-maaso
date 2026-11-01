import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

const _accountDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  AppCapabilitySnapshotService service() => AppCapabilitySnapshotService(
    resolver: AppPlatformCapabilitySnapshotResolver(
      routeIds: const <String>{'settings', 'advanced_features'},
      skillIds: const <String>{'app_navigate'},
    ),
    initialContext: AppCapabilitySnapshotContext(
      hostPlatform: AppHostPlatform.macos,
      rolloutGeneration: 0,
    ),
  );

  test('identical refresh preserves generation and lease', () async {
    final owner = service();
    final lease = owner.capture();
    var invalidated = false;
    lease.whenInvalidated.then((_) => invalidated = true);

    owner.refresh(owner.context);
    await Future<void>.delayed(Duration.zero);

    expect(owner.value.generation, 0);
    expect(owner.isCurrent(lease), isTrue);
    expect(invalidated, isFalse);
    owner.closeLifecycle();
  });

  test('account and rollout changes invalidate the prior generation', () async {
    final owner = service();
    final initial = owner.capture();
    final invalidated = expectLater(initial.whenInvalidated, completes);

    owner.activateAccount(
      accountScopeDigest: _accountDigest,
      accountGeneration: 7,
    );
    await invalidated;

    expect(owner.value.generation, 1);
    expect(owner.isCurrent(initial), isFalse);
    final accountLease = owner.capture();

    owner.refresh(owner.context.copyWith(rolloutGeneration: 1));
    await expectLater(accountLease.whenInvalidated, completes);
    expect(owner.value.generation, 2);
    owner.closeLifecycle();
  });

  test('wrong account generation cannot clear the current account', () {
    final owner = service();
    owner.activateAccount(
      accountScopeDigest: _accountDigest,
      accountGeneration: 7,
    );

    expect(owner.deactivateAccount(accountGeneration: 6), isFalse);
    expect(owner.context.accountGeneration, 7);
    expect(owner.deactivateAccount(accountGeneration: 7), isTrue);
    expect(owner.context.accountGeneration, isNull);
    owner.closeLifecycle();
  });

  test('lease acquisition rejects unavailable and undeclared keys', () {
    final owner = AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{'advanced_features'},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.web,
        rolloutGeneration: 0,
      ),
    );
    final unavailable = owner.acquireLease(<AppCapabilityKey>[
      AppCapabilityKey.route('advanced_features'),
    ], requireVisible: true);
    final unknown = owner.acquireLease(<AppCapabilityKey>[
      AppCapabilityKey.skill('unknown'),
    ]);

    expect(unavailable.isGranted, isFalse);
    expect(unknown.isGranted, isFalse);
    expect(unknown.rejected.values.single, const <String>{
      'capability_not_declared',
    });
    owner.closeLifecycle();
  });

  test(
    'rollout binding publishes one generation per event and closes',
    () async {
      final owner = service();
      final changes = StreamController<Object?>.broadcast(sync: true);
      var rolloutGeneration = 0;
      owner.bindRollout(
        changes: changes.stream,
        generation: () => rolloutGeneration,
      );
      final lease = owner.capture();

      rolloutGeneration = 1;
      changes.add(null);
      await expectLater(lease.whenInvalidated, completes);
      expect(owner.value.generation, 1);

      final current = owner.capture();
      owner.closeLifecycle();
      await expectLater(current.whenInvalidated, completes);
      expect(owner.isCurrent(current), isFalse);
      await changes.close();
    },
  );

  test('leases cannot cross service instances with equal generations', () {
    final first = service();
    final second = service();
    final lease = first.capture();

    expect(first.value.generation, second.value.generation);
    expect(second.isCurrent(lease), isFalse);
    expect(first.capture().cacheKey, isNot(second.capture().cacheKey));
    first.closeLifecycle();
    second.closeLifecycle();
  });
}
