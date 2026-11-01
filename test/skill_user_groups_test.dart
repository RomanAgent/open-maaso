import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/skills/application/skill_user_groups.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() async => appServices.reset());

  test('each active execution ID belongs to one product or internal group', () {
    final ids = SkillUserGroupCatalog.all
        .expand((group) => group.skillIds)
        .toList();
    expect(ids.toSet().length, ids.length);
    expect(
      ids.toSet().intersection(SkillUserGroupCatalog.internalSkillIds),
      isEmpty,
    );
    expect({
      ...ids,
      ...SkillUserGroupCatalog.internalSkillIds,
    }, SkillCatalog.all.map((spec) => spec.id).toSet());
    expect(
      SkillUserGroupCatalog.all.map((group) => group.id).toSet().length,
      9,
    );
    expect(SkillUserGroupCatalog.internalSkillIds, contains('project_control'));
    expect(ids, isNot(contains('avatar_motion_learning')));
  });

  test('groups preserve runtime permission and optional boundaries', () {
    final projection = SkillUserGroupCatalog.byId('projection')!;
    expect(projection.optionalSpecs.map((spec) => spec.id), [
      'bluetooth',
      'ble_yoturetoys_projector',
    ]);
    final resolver = AppPlatformCapabilitySnapshotResolver(
      routeIds: AppRouteCatalog.destinations.map(
        (destination) => destination.id,
      ),
      skillIds: SkillCatalog.all.map((spec) => spec.id),
      skillRequirements: SkillCatalog.capabilityRequirements,
    );
    final web = AppCapabilitySnapshotService(
      resolver: resolver,
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.web,
        rolloutGeneration: 0,
      ),
    ).value;
    expect(projection.canEnable(web), isFalse);
    expect(SkillUserGroupCatalog.byId('memory')!.isCore, isTrue);
    expect(SkillUserGroupCatalog.byId('persona')!.isCore, isTrue);
    expect(SkillUserGroupCatalog.byId('creation')!.isCore, isTrue);
    expect(SkillUserGroupCatalog.byId('web_search')!.isCore, isFalse);
    expect(
      SkillUserGroupCatalog.byId('companion_activity')!.isVisible(null),
      isFalse,
    );
    expect(
      SkillUserGroupCatalog.byId('web_search')!.skillIds,
      isNot(contains('applet_discovery')),
    );
  });

  test(
    'consolidated counters preserve original names and restart history',
    () async {
      final database = await databaseFactoryMemory.openDatabase('group-usage');
      var current = true;
      final scope = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'groups',
      );
      Future<SkillUsageService> create() => SkillUsageService(
        database: database,
        accountScopeDigest: scope.accountDigest,
        isCurrent: () => current,
      ).init(observeLifecycle: false);
      final first = await create();
      for (final (name, success) in [
        ('FreeformSurface', true),
        ('Creator', false),
        ('Http', true),
      ]) {
        await first
            .start(
              skillName: name,
              method: 'execute',
              channel: SkillUsageChannel.native,
            )!
            .finish(succeeded: success);
      }
      await first.whenSettled;
      await first.shutdown();
      final restored = await create();
      final creation = SkillUserGroupCatalog.byId('creation')!;
      final summary = creation.usage(restored);
      expect(summary.started, 2);
      expect(summary.succeeded, 1);
      expect(summary.failed, 1);
      expect(summary.lastUsed, isNotNull);
      expect(restored.forSkill('Http').started, 1);
      current = false;
      expect(creation.usage(restored).started, 0);
      await restored.shutdown();
      await database.close();
    },
  );
}
