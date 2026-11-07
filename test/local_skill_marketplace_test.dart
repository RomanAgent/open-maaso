import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/remote_skill_catalog_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late DBService database;
  late SkillMarketplaceService service;
  late Directory temp;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_Storage());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    appServices.put(AuthSessionService());
    database = appServices.put(DBService());
    await database.init(
      factory: databaseFactoryMemory,
      path: 'local-skills.db',
    );
    service = _service(database);
    temp = await Directory.systemTemp.createTemp('open-maaso-local-skills-');
  });
  tearDown(() async {
    service.onClose();
    await appServices.reset();
    await temp.delete(recursive: true);
  });

  test(
    'original marketplace contract persists local installs and likes',
    () async {
      final catalog = await service.listCatalog();
      expect(catalog, hasLength(3));
      expect(await service.listCatalog(query: '游戏'), hasLength(1));
      final skill = catalog.first;
      final installed = await service.install(
        skillId: '${skill.skillVersionId}',
        agentId: 'self',
        acceptedPermissions: {},
      );
      expect(installed.isActive, isTrue);
      await service.setLike(skillVersionId: skill.skillVersionId, liked: true);
      final reopened = _service(database);
      addTearDown(reopened.onClose);
      expect(
        (await reopened.listInstallations(agentId: 'self')).single.isActive,
        isTrue,
      );
      final persisted = await reopened.getSkill('${skill.skillVersionId}');
      expect(persisted.likeCount, 1);
      expect(persisted.activeInstallCount, 1);
      await reopened.setInstallationStatus(
        installationId: installed.installationId,
        status: SkillInstallationStatus.disabled,
        reason: 'owner paused',
      );
      expect(
        (await reopened.getSkill('${skill.skillVersionId}')).activeInstallCount,
        0,
      );
      expect(
        (await service.listInstallations(agentId: 'different-agent')),
        isEmpty,
      );
    },
  );

  test(
    'imports declarative package locally and enforces permission acceptance',
    () async {
      final package = await _package(temp, permissions: ['conversation.read']);
      final submission = await service.uploadAndSubmit(
        package: package,
        visibility: SkillVisibility.private,
        versionName: '1.2.0',
      );
      final skill = await service.getSkill('${submission.skillVersionId}');
      expect(skill.instruction, 'Observe two facts before answering.');
      expect(skill.coverAssetUrl, isEmpty);
      await expectLater(
        service.install(
          skillId: '${skill.skillVersionId}',
          agentId: 'self',
          acceptedPermissions: {},
        ),
        throwsStateError,
      );
      expect(
        (await service.install(
          skillId: '${skill.skillVersionId}',
          agentId: 'self',
          acceptedPermissions: {'conversation.read'},
        )).isActive,
        isTrue,
      );
      final unsafe = await _package(temp, permissions: ['world.effect.play']);
      await expectLater(
        service.uploadAndSubmit(
          package: unsafe,
          visibility: SkillVisibility.private,
          versionName: '2',
        ),
        throwsStateError,
      );
      expect(await service.listCatalog(), hasLength(4));
    },
  );

  test(
    'evolution saves locally with explicit structural-only test evidence',
    () async {
      final skill = (await service.listCatalog()).first;
      final draft = await service.forkSkill(skill.skillVersionId);
      expect(
        (await service.runEvolutionStandardTest(draft.id)).lastTest?.passed,
        isFalse,
      );
      await service.addEvolutionCase(
        draftId: draft.id,
        prompt: 'Help me plan.',
        expectedBehavior: 'Ask about the goal.',
      );
      final tested = await service.runEvolutionStandardTest(draft.id);
      expect(tested.hasFreshPassingTest, isTrue);
      expect(tested.lastTest?.report['semanticEvaluation'], isFalse);
      await service.updateEvolutionDraft(
        draftId: draft.id,
        title: 'Edited plan',
        summary: 'Local summary',
        strategy: 'Ask about the goal and list steps.',
        visibility: SkillVisibility.private,
        versionName: '2.0.0',
      );
      await expectLater(
        service.publishEvolutionDraft(draft.id),
        throwsStateError,
      );
      await service.runEvolutionStandardTest(draft.id);
      final saved = await service.publishEvolutionDraft(draft.id);
      final lineage = await service.getSkillLineage(saved.skillVersionId);
      expect(lineage, hasLength(2));
      expect(lineage.first.skill.skillVersionId, skill.skillVersionId);
      expect(lineage.last.isCurrent, isTrue);
      expect((await service.getEvolutionDraft(draft.id)).isPublished, isTrue);
    },
  );

  test('legacy remote catalog reads installed local prompt cards', () async {
    final registry = InstalledSkillRegistry(database: database);
    final skill = (await service.listCatalog()).first;
    await registry.upsert(agentId: 'self', skill: skill);
    final catalog = RemoteSkillCatalogService(
      localEdition: true,
      registry: registry,
    );
    final specs = await catalog.fetchCatalog();
    expect(specs.single.name, skill.title);
    expect(specs.single.jsBundleUrl, isNull);
    expect(specs.single.metadata['source'], 'local');
    expect(await catalog.installSkill(specs.single.id), isTrue);
    expect(await catalog.installSkill('not-installed'), isFalse);
  });
}

SkillMarketplaceService _service(DBService database) => SkillMarketplaceService(
  localEdition: true,
  localDatabase: database,
  httpClient: MockClient(
    (_) async => throw StateError('Backend HTTP must not run'),
  ),
);

Future<File> _package(
  Directory temp, {
  required List<String> permissions,
}) async {
  final manifest = utf8.encode(
    jsonEncode({
      'schema': 'maaso.skill.v1',
      'key': 'local-observe',
      'title': 'Local observer',
      'summary': 'Observe then answer.',
      'category': 'observation',
      'instruction': 'Observe two facts before answering.',
      'permissions': permissions,
      'examples': ['What do you see?'],
      'ignoredNativeCode': 'never imported',
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  return File(
    '${temp.path}/skill.maaso-skill',
  ).writeAsBytes(ZipEncoder().encodeBytes(archive));
}

class _Storage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String? value) async => true;
}
