import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'stale World permission cards are omitted from every marketplace list',
    () async {
      final service = await _createMarketplace(
        MockClient(
          (_) async => _ok([
            {
              'skillVersionId': 71,
              'skillKey': 'old-effect',
              'title': 'Retired effect',
              'publisherId': 'author',
              'permissions': ['world.effect.play'],
              'safetyStatus': 'passed',
            },
            {
              'skillVersionId': 72,
              'skillKey': 'ordinary-guide',
              'title': 'Ordinary guide',
              'publisherId': 'author',
              'permissions': ['conversation.read'],
              'safetyStatus': 'passed',
              'effects': {'legacy': 'unknown metadata'},
            },
          ]),
        ),
      );
      for (final load in [
        service.listCatalog,
        service.listRankings,
        service.listMine,
      ]) {
        final listed = await load();
        expect(listed.map((skill) => skill.skillVersionId), [72]);
        expect(listed.single.toSanitizedJson().containsKey('effects'), isFalse);
      }
    },
  );

  test(
    'retired permission install refuses before any external request',
    () async {
      var requests = 0;
      final service = await _createMarketplace(
        MockClient((_) async {
          requests++;
          throw StateError('must not install a retired permission');
        }),
      );
      await expectLater(
        service.install(
          skillId: '71',
          agentId: 'self',
          acceptedPermissions: {'world.effect.play'},
        ),
        throwsStateError,
      );
      expect(requests, 0);
    },
  );

  test(
    'all legacy lists omit retired official content but preserve author lookalikes',
    () async {
      final service = await _createMarketplace(
        MockClient(
          (request) async => _ok([
            {
              'skillVersionId': 41,
              'submissionId': 141,
              'skillKey': 'quick-observe',
              'title': 'Quick Observe',
              'publisherId': MarketplaceSkill.officialPublisherId,
              'safetyStatus': 'passed',
            },
            {
              'skillVersionId': 42,
              'submissionId': 142,
              'skillKey': 'quick-observe',
              'title': 'Quick Observe',
              'publisherId': 'author-42',
              'safetyStatus': 'passed',
            },
            {
              'skillVersionId': 43,
              'submissionId': 143,
              'skillKey': 'official-guide',
              'title': 'Quick Observe',
              'publisherId': MarketplaceSkill.officialPublisherId,
              'safetyStatus': 'passed',
            },
          ]),
        ),
      );
      for (final load in [
        service.listCatalog,
        service.listRankings,
        service.listMine,
      ]) {
        final skills = await load();
        expect(skills.map((skill) => skill.skillVersionId), [42, 43]);
      }
      expect(service.catalog.map((skill) => skill.skillVersionId), [42, 43]);
      expect(service.rankings.map((skill) => skill.skillVersionId), [42, 43]);
      expect(service.mySkills.map((skill) => skill.skillVersionId), [42, 43]);
    },
  );

  test('catalog uses bearer auth and decodes the free Skill contract', () async {
    final service = await _createMarketplace(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/skills/catalog?query=writer&locale=zh',
        );
        expect(request.headers['authorization'], 'Bearer access-token');
        return _ok([
          {
            'skillVersionId': 42,
            'submissionId': 7,
            'skillKey': 'copywriter',
            'title': 'Copywriter',
            'summary': 'Creates concise drafts.',
            'publisherId': 'author-7ab1',
            'versionName': '1.0.0',
            'category': 'reasoning',
            'permissions': ['conversation.read'],
            'manifestDigest': _digest('a'),
            'isFree': true,
            'likeCount': 12,
            'activeInstallCount': 7,
            'likedByMe': true,
          },
        ]);
      }),
    );
    final locale = appServices.put(LocaleConfigService());
    locale.locale.value = AppLocale.zh;

    final catalog = await service.listCatalog(query: 'writer');

    expect(catalog, hasLength(1));
    expect(catalog.single.skillVersionId, 42);
    expect(catalog.single.category, SkillCategory.reasoning);
    expect(catalog.single.permissions, {'conversation.read'});
    expect(catalog.single.isFree, isTrue);
    expect(catalog.single.publisherId, 'author-7ab1');
    expect(catalog.single.likeCount, 12);
    expect(catalog.single.activeInstallCount, 7);
    expect(catalog.single.likedByMe, isTrue);
    expect(service.catalog.single.title, 'Copywriter');
  });

  test(
    'skill detail uses resolved locale and preserves server author content',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/skills/42?locale=zh',
          );
          return _ok({
            'skillVersionId': 42,
            'submissionId': 7,
            'skillKey': 'author-skill',
            'title': '作者原文',
            'summary': '保持作者提交的内容。',
            'publisherId': 'author-7ab1',
            'versionName': '1.0.0',
            'category': 'reasoning',
            'permissions': <String>[],
            'manifestDigest': _digest('a'),
            'isFree': true,
          });
        }),
      );
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;

      final skill = await service.getSkill('42');

      expect(skill.title, '作者原文');
      expect(skill.summary, '保持作者提交的内容。');
    },
  );

  test('rankings preserve the server order and social proof', () async {
    final service = await _createMarketplace(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/skills/rankings?sort=popular&locale=en',
        );
        return _ok([
          {
            'skillVersionId': 42,
            'submissionId': 7,
            'skillKey': 'copywriter',
            'title': 'Copywriter',
            'summary': 'Creates concise drafts.',
            'publisherId': 'author-7ab1',
            'versionName': '1.0.0',
            'category': 'reasoning',
            'permissions': <String>[],
            'manifestDigest': _digest('a'),
            'isFree': true,
            'likeCount': 22,
            'activeInstallCount': 11,
            'likedByMe': false,
          },
        ]);
      }),
    );

    final ranked = await service.listRankings();

    expect(ranked.single.title, 'Copywriter');
    expect(ranked.single.likeCount, 22);
    expect(service.rankings.single.skillVersionId, 42);
  });

  test(
    'my Skills preserve author-only visibility and automatic safety state',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/skills/mine?locale=en',
          );
          return _ok([
            {
              'skillVersionId': 0,
              'submissionId': 7,
              'skillKey': 'unsafe-draft',
              'title': 'Unsafe Draft',
              'summary': 'Rejected before publishing.',
              'publisherId': 'author-7ab1',
              'versionName': '',
              'category': '',
              'permissions': <String>[],
              'manifestDigest': '',
              'visibility': 'private',
              'safetyStatus': 'rejected',
              'isFree': true,
            },
          ]);
        }),
      );

      final mine = await service.listMine();

      expect(mine.single.visibility, SkillVisibility.private);
      expect(mine.single.safetyStatus, SkillSafetyStatus.rejected);
      expect(mine.single.isRejected, isTrue);
    },
  );

  test(
    'install serializes permissions without a caller account or purchase',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/skills/42/install',
          );
          expect(request.headers['authorization'], 'Bearer access-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'agentId': 'self',
            'acceptedPermissions': ['conversation.read', 'memory.write'],
          });
          expect(body, isNot(contains('accountUuid')));
          expect(body, isNot(contains('purchase')));
          return _ok({
            'installationId': 9,
            'status': 'active',
            'skillVersionId': 42,
            'agentId': 'self',
          });
        }),
      );
      service.catalog.assign(
        MarketplaceSkill.fromJson({
          'skillVersionId': 42,
          'submissionId': 7,
          'skillKey': 'copywriter',
          'title': 'Copywriter',
          'summary': 'Creates concise drafts.',
          'publisherId': 'author-7ab1',
          'versionName': '1.0.0',
          'category': 'reasoning',
          'permissions': <String>[],
          'manifestDigest': _digest('a'),
          'isFree': true,
          'activeInstallCount': 4,
        }),
      );

      final result = await service.install(
        skillId: '42',
        agentId: 'self',
        acceptedPermissions: {'memory.write', 'conversation.read'},
      );

      expect(result.installationId, 9);
      expect(result.status, 'active');
      expect(service.installedSkillVersionIds, {42});
      expect(service.installationForVersion(42)?.isActive, isTrue);
      expect(service.catalog.single.activeInstallCount, 5);
    },
  );

  test(
    'zero-permission Skill installs with an explicit empty consent list',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/skills/43/install',
          );
          expect(jsonDecode(request.body), {
            'agentId': 'self',
            'acceptedPermissions': <String>[],
          });
          return _ok({
            'installationId': 10,
            'status': 'active',
            'skillVersionId': 43,
            'agentId': 'self',
          });
        }),
      );

      final result = await service.install(
        skillId: '43',
        agentId: 'self',
        acceptedPermissions: <String>{},
      );

      expect(result.isActive, isTrue);
      expect(service.installedSkillVersionIds, {43});
    },
  );

  test('only safety-passed or legacy Skills are installable', () {
    MarketplaceSkill skillWithSafety(String? safetyStatus) =>
        MarketplaceSkill.fromJson({
          'skillVersionId': 43,
          'submissionId': 8,
          'skillKey': 'quick-observe',
          'title': 'Quick Observe',
          'summary': 'Observe first.',
          'publisherId': 'official',
          'versionName': '1.0.0',
          'category': 'observation',
          'permissions': <String>[],
          'manifestDigest': _digest('q'),
          'isFree': true,
          if (safetyStatus != null) 'safetyStatus': safetyStatus,
        });

    expect(skillWithSafety('passed').canInstall, isTrue);
    expect(skillWithSafety(null).canInstall, isTrue);
    expect(skillWithSafety('pending').canInstall, isFalse);
    expect(skillWithSafety('rejected').canInstall, isFalse);
  });

  test('installation list and status changes stay server authoritative', () async {
    var requestIndex = 0;
    final service = await _createMarketplace(
      MockClient((request) async {
        requestIndex += 1;
        if (requestIndex == 1) {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/skills/installations?agentId=self',
          );
          return _ok([
            {
              'installationId': 9,
              'status': 'active',
              'skillVersionId': 42,
              'agentId': 'self',
            },
          ]);
        }
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/skills/installations/9/status',
        );
        expect(jsonDecode(request.body), {
          'status': 'uninstalled',
          'reason': 'Removed by user',
        });
        return _ok({
          'installationId': 9,
          'status': 'uninstalled',
          'skillVersionId': 42,
          'agentId': 'self',
        });
      }),
    );
    service.catalog.assign(
      MarketplaceSkill.fromJson({
        'skillVersionId': 42,
        'submissionId': 7,
        'skillKey': 'copywriter',
        'title': 'Copywriter',
        'summary': 'Creates concise drafts.',
        'publisherId': 'author-7ab1',
        'versionName': '1.0.0',
        'category': 'reasoning',
        'permissions': <String>[],
        'manifestDigest': _digest('a'),
        'isFree': true,
        'activeInstallCount': 1,
      }),
    );

    final installed = await service.listInstallations(agentId: 'self');
    expect(installed.single.isActive, isTrue);

    final removed = await service.setInstallationStatus(
      installationId: 9,
      status: SkillInstallationStatus.uninstalled,
      reason: 'Removed by user',
    );

    expect(removed.isUninstalled, isTrue);
    expect(service.isInstalledVersion(42), isFalse);
    expect(service.installedSkillVersionIds, isEmpty);
    expect(service.catalog.single.activeInstallCount, 0);
  });

  test('like state is updated in every loaded Skill collection', () async {
    var requestIndex = 0;
    final service = await _createMarketplace(
      MockClient((request) async {
        requestIndex += 1;
        if (requestIndex == 1) {
          return _ok([
            {
              'skillVersionId': 42,
              'submissionId': 7,
              'skillKey': 'copywriter',
              'title': 'Copywriter',
              'summary': 'Creates concise drafts.',
              'publisherId': 'author-7ab1',
              'versionName': '1.0.0',
              'category': 'reasoning',
              'permissions': <String>[],
              'manifestDigest': _digest('a'),
              'isFree': true,
              'likeCount': 3,
              'activeInstallCount': 1,
              'likedByMe': false,
            },
          ]);
        }
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/skills/42/likes/status',
        );
        expect(jsonDecode(request.body), {'liked': true});
        return _ok({
          'skillVersionId': 42,
          'likeCount': 4,
          'activeInstallCount': 1,
          'likedByMe': true,
        });
      }),
    );

    await service.listCatalog();
    final social = await service.setLike(skillVersionId: 42, liked: true);

    expect(social.likedByMe, isTrue);
    expect(service.catalog.single.likeCount, 4);
    expect(service.catalog.single.likedByMe, isTrue);
  });

  test(
    'upload hashes local bytes before signed PUT then submits visibility',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'maaso-skill-test',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final package = File('${temporary.path}/trail-observer.maaso-skill');
      final bytes = utf8.encode('declarative-skill-package');
      await package.writeAsBytes(bytes);
      final digest = sha256.convert(bytes).toString();
      var requestIndex = 0;
      final service = await _createMarketplace(
        MockClient((request) async {
          requestIndex += 1;
          switch (requestIndex) {
            case 1:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/uploads');
              expect(jsonDecode(request.body), {
                'contentLength': bytes.length,
                'sha256': digest,
              });
              return _ok({
                'uploadId': 'upload-1',
                'uploadUrl': 'https://uploads.example.test/skill',
                'uploadHeaders': {'content-type': 'application/zip'},
                'expiresAt': '2026-07-15T10:15:00Z',
                'maxBytes': 1048576,
              });
            case 2:
              expect(request.method, 'PUT');
              expect(
                request.url.toString(),
                'https://uploads.example.test/skill',
              );
              expect(request.headers['content-type'], 'application/zip');
              expect(request.bodyBytes, bytes);
              return http.Response('', 200);
            case 3:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/uploads/upload-1/complete');
              return _ok({'uploadId': 'upload-1', 'status': 'ready'});
            case 4:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/submissions');
              expect(jsonDecode(request.body), {
                'uploadId': 'upload-1',
                'visibility': 'private',
                'versionName': '1.0.0',
                'coverAssetUrl': '',
              });
              return _ok({
                'submissionId': 7,
                'skillVersionId': 42,
                'status': 'published',
                'visibility': 'private',
                'safetyStatus': 'passed',
              });
            default:
              throw StateError('unexpected request $requestIndex');
          }
        }),
      );

      final result = await service.uploadAndSubmit(
        package: package,
        visibility: SkillVisibility.private,
        versionName: '1.0.0',
      );

      expect(requestIndex, 4);
      expect(result.skillVersionId, 42);
      expect(result.visibility, SkillVisibility.private);
      expect(result.safetyStatus, SkillSafetyStatus.passed);
    },
  );

  test(
    'mastery evidence sends opaque fields and returns only a display bucket',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api-test.futurpals.com.cn/v1/agents/self/skill-mastery/events',
          );
          expect(jsonDecode(request.body), {
            'eventId': 'evidence-1',
            'skillVersionId': 42,
            'source': 'conversation',
            'quality': 3,
            'digest': _digest('a'),
            'occurredAt': '2026-07-15T09:59:00.000Z',
          });
          return _ok({'masteryBucket': 'growing'});
        }),
      );

      final result = await service.recordMasteryEvidence(
        agentId: 'self',
        eventId: 'evidence-1',
        skillVersionId: 42,
        source: SkillTrainingSource.conversation,
        quality: 3,
        digest: _digest('a'),
        occurredAt: DateTime.utc(2026, 7, 15, 9, 59),
      );

      expect(result.bucket, MasteryBucket.growing);
    },
  );

  test(
    'Skill evolution serializes fork edit training test publish and lineage',
    () async {
      var requestIndex = 0;
      final service = await _createMarketplace(
        MockClient((request) async {
          requestIndex += 1;
          switch (requestIndex) {
            case 1:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/42/forks');
              return _ok(_evolutionDraftJson(revision: 1));
            case 2:
              expect(request.method, 'PATCH');
              expect(request.url.path, '/v1/skills/drafts/draft-1');
              expect(jsonDecode(request.body), {
                'title': 'Observer Remix',
                'summary': 'Compares evidence.',
                'strategy':
                    'Compare two visible clues before selecting one action.',
                'visibility': 'public',
                'versionName': '1.1.0',
              });
              return _ok(_evolutionDraftJson(revision: 2));
            case 3:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/drafts/draft-1/cases');
              expect(jsonDecode(request.body), {
                'prompt': 'Which path is safer?',
                'expectedBehavior': 'Compare two landmarks first.',
                'notes': 'World trial',
              });
              return _ok(
                _evolutionDraftJson(
                  revision: 3,
                  cases: [
                    {
                      'id': 9,
                      'prompt': 'Which path is safer?',
                      'expectedBehavior': 'Compare two landmarks first.',
                      'notes': 'World trial',
                      'sortOrder': 0,
                    },
                  ],
                ),
              );
            case 4:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/drafts/draft-1/tests');
              return _ok(
                _evolutionDraftJson(
                  revision: 3,
                  cases: [
                    {
                      'id': 9,
                      'prompt': 'Which path is safer?',
                      'expectedBehavior': 'Compare two landmarks first.',
                      'notes': 'World trial',
                      'sortOrder': 0,
                    },
                  ],
                  lastTest: {
                    'id': 'test-1',
                    'draftRevision': 3,
                    'status': 'passed',
                    'totalCases': 2,
                    'passedCases': 2,
                    'score': 100,
                    'report': {'strategyPassed': true},
                    'createdAt': '2026-07-31T05:00:00.000Z',
                  },
                ),
              );
            case 5:
              expect(request.method, 'POST');
              expect(request.url.path, '/v1/skills/drafts/draft-1/publish');
              return _ok({
                'submissionId': 8,
                'skillVersionId': 43,
                'status': 'published',
                'visibility': 'public',
                'safetyStatus': 'passed',
              });
            case 6:
              expect(request.method, 'GET');
              expect(request.url.path, '/v1/skills/43/lineage');
              expect(request.url.queryParameters['locale'], 'en');
              return _ok([
                {
                  'skill': {
                    'skillVersionId': 42,
                    'submissionId': 7,
                    'skillKey': 'observer',
                    'title': 'Observer',
                    'summary': 'Observes clues.',
                    'publisherId': 'author-root',
                    'versionName': '1.0.0',
                    'category': 'observation',
                    'permissions': <String>[],
                    'manifestDigest': _digest('a'),
                    'isFree': true,
                  },
                  'parentSkillVersionId': null,
                  'rootSkillVersionId': 42,
                  'lineageDepth': 0,
                  'strategy': 'Observe visible clues.',
                  'isCurrent': false,
                },
                {
                  'skill': {
                    'skillVersionId': 43,
                    'submissionId': 8,
                    'skillKey': 'observer-fork-12345678',
                    'title': 'Observer Remix',
                    'summary': 'Compares evidence.',
                    'publisherId': 'author-fork',
                    'versionName': '1.1.0',
                    'category': 'observation',
                    'permissions': <String>[],
                    'manifestDigest': _digest('b'),
                    'isFree': true,
                  },
                  'parentSkillVersionId': 42,
                  'rootSkillVersionId': 42,
                  'lineageDepth': 1,
                  'strategy':
                      'Compare two visible clues before selecting one action.',
                  'isCurrent': true,
                },
              ]);
            default:
              throw StateError('unexpected request $requestIndex');
          }
        }),
      );

      final fork = await service.forkSkill(42);
      expect(fork.id, 'draft-1');
      final edited = await service.updateEvolutionDraft(
        draftId: fork.id,
        title: 'Observer Remix',
        summary: 'Compares evidence.',
        strategy: 'Compare two visible clues before selecting one action.',
        visibility: SkillVisibility.public,
        versionName: '1.1.0',
      );
      expect(edited.revision, 2);
      final trained = await service.addEvolutionCase(
        draftId: fork.id,
        prompt: 'Which path is safer?',
        expectedBehavior: 'Compare two landmarks first.',
        notes: 'World trial',
      );
      expect(trained.cases.single.id, 9);
      final tested = await service.runEvolutionStandardTest(fork.id);
      expect(tested.hasFreshPassingTest, isTrue);
      final published = await service.publishEvolutionDraft(fork.id);
      expect(published.skillVersionId, 43);
      final lineage = await service.getSkillLineage(43);
      expect(lineage, hasLength(2));
      expect(lineage.last.parentSkillVersionId, 42);
      expect(lineage.last.isCurrent, isTrue);
      expect(requestIndex, 6);
    },
  );

  test(
    'Skill evolution training cases support server-authoritative delete',
    () async {
      final service = await _createMarketplace(
        MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/v1/skills/drafts/draft-1/cases/9');
          return _ok(_evolutionDraftJson(revision: 4));
        }),
      );

      final draft = await service.deleteEvolutionCase(
        draftId: 'draft-1',
        caseId: 9,
      );

      expect(draft.revision, 4);
      expect(draft.cases, isEmpty);
    },
  );

  test('keeps a plain-text catalog failure as an HTTP error', () async {
    final service = await _createMarketplace(
      MockClient((_) async => http.Response('404 page not found', 404)),
    );

    await expectLater(
      service.listCatalog(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Marketplace request failed: HTTP 404',
        ),
      ),
    );
    expect(service.error.value, 'Marketplace request failed: HTTP 404');
  });
}

http.Response _ok(Object data) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'success',
    'traceId': 'trace-test',
    'data': data,
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

String _digest(String character) => List<String>.filled(64, character).join();

Map<String, dynamic> _evolutionDraftJson({
  required int revision,
  List<Map<String, dynamic>> cases = const [],
  Map<String, dynamic>? lastTest,
}) {
  return {
    'id': 'draft-1',
    'sourceSkillVersionId': 42,
    'rootSkillVersionId': 42,
    'skillKey': 'observer-fork-12345678',
    'title': 'Observer Remix',
    'summary': 'Compares evidence.',
    'coverAssetUrl': '',
    'category': 'observation',
    'strategy': 'Compare two visible clues before selecting one action.',
    'visibility': 'public',
    'versionName': '1.1.0',
    'status': 'draft',
    'revision': revision,
    'cases': cases,
    if (lastTest != null) 'lastTest': lastTest,
    'createdAt': '2026-07-31T04:30:00.000Z',
    'updatedAt': '2026-07-31T05:00:00.000Z',
  };
}

Future<SkillMarketplaceService> _createMarketplace(http.Client client) async {
  final storage = _MemorySecureStorageService();
  appServices.put<SecureStorageService>(storage);
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async {
        throw UnimplementedError('Marketplace tests must not refresh auth');
      }),
    ),
  );
  await auth.init();
  auth.session.value = MaasoAuthSession(
    accountUuid: 'buyer-1',
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
  return SkillMarketplaceService(httpClient: client);
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = {};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
