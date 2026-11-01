import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_agent_document.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:sembast/sembast_memory.dart';

Map<String, Object?> payload(String document) => {
  'title': 'Canvas Document',
  'summary': 'An offline canvas with full instructions.',
  'kind': 'floatingCanvas',
  'rendering': 'canvas',
  'experienceType': 'utility',
  'html': '<canvas id="doc"></canvas>',
  'css': '#doc{width:100%}',
  'js': 'window.ready=true;',
  'manifest': {'events': [], 'actions': []},
  'skillInstructions': document,
};
Map<String, Object?> catalog(String document) => {
  'id': 'applet-1',
  'title': 'Canvas Document',
  'type': 'game',
  'summary': 'Full game instructions.',
  'author': {
    'agentId': 'aa_0123456789abcdef0123456789abcdef',
    'displayName': 'Agent 0123456789ABCDEF',
    'verified': false,
  },
  'shareUrl': 'https://api.example.test/g/doc',
  'updatedAt': '2026-10-07T08:00:00Z',
  'skillInstructions': document,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    '3600 Chinese characters and Markdown whitespace survive real widget save and cold offline reopen',
    () async {
      final document = ' \n# 游玩说明\n${'游' * 3600}\n\n ';
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'agent-doc-roundtrip.db',
      );
      addTearDown(db.close);
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final shown =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(payload(document)),
                    ])
                    as String,
              )
              as Map;
      expect(shown['widgetId'], isA<int>());
      expect(runtime.activeProject.value!.skillInstructions, document);
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['skillInstructions'], document);
      expect(
        utf8.encode(saved.spec['skillInstructions'] as String),
        utf8.encode(document),
      );
      await runtime.close();
      final coldRuntime = SurfaceRuntime();
      final cold = FreeformSurfaceSkill(agentId: 'self', runtime: coldRuntime);
      final reopened =
          jsonDecode(
                await cold.methods['reopenSurface']!([
                      jsonEncode({'id': saved.id}),
                    ])
                    as String,
              )
              as Map;
      expect(reopened['widgetId'], saved.id);
      expect(coldRuntime.activeProject.value!.skillInstructions, document);
      expect(
        (await db.getAllWidgets()).single.spec['skillInstructions'],
        document,
      );
      expect(
        SurfaceProject.fromJson(
          coldRuntime.activeProject.value!.toJson(),
        ).skillInstructions,
        document,
      );
      await coldRuntime.close();
    },
  );

  test(
    'public catalog and its copy preserve full documents without trimming',
    () {
      final document = ' \n${'说明😀' * 1800}\n ';
      final item = AppletCatalogItem.fromJson(
        catalog(document),
        trustedOrigin: Uri.parse('https://api.example.test'),
      );
      expect(item.skillInstructions, document);
      expect(item.copyWith(viewCount: 1).skillInstructions, document);
    },
  );

  test(
    'edit, explicit apply, and version history preserve complete documents',
    () async {
      final original = ' \n# Original\n${'甲' * 3600}\n ';
      final edited = ' \n# Edited\n${'乙😀' * 1800}\n\n ';
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'agent-doc-edit-roundtrip.db',
      );
      addTearDown(db.close);
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      await skill.methods['showSurface']!([jsonEncode(payload(original))]);
      final first = (await db.getAllWidgets()).single;
      final surfaceId = first.spec['surfaceId'];
      final result =
          jsonDecode(
                await skill.methods['editSurface']!([
                      jsonEncode({
                        'surfaceId': surfaceId,
                        'skillInstructions': edited,
                      }),
                    ])
                    as String,
              )
              as Map;
      expect(result['status'], 'draft_ready');
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['skillInstructions'], original);
      final draft = SurfaceVersionDraft.tryParse(
        saved.spec['pendingVersionDraft'],
      )!;
      expect(draft.source['skillInstructions'], edited);
      final applied = await applyAppletVersionDraft(
        item: saved,
        draftId: draft.id,
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        firstFrameReady: true,
      );
      expect(applied.spec['skillInstructions'], edited);
      final history = SurfaceVersionHistory.read(
        applied.spec,
        title: applied.title,
      );
      expect(history.versions.map((v) => v.source['skillInstructions']), [
        original,
        edited,
      ]);
      await runtime.close();
      final coldRuntime = SurfaceRuntime();
      final coldSkill = FreeformSurfaceSkill(
        agentId: 'self',
        runtime: coldRuntime,
      );
      await coldSkill.methods['reopenSurface']!([
        jsonEncode({'id': saved.id}),
      ]);
      expect(coldRuntime.activeProject.value!.skillInstructions, edited);
      final rejected =
          jsonDecode(
                await coldSkill.methods['editSurface']!([
                      jsonEncode({
                        'surfaceId': surfaceId,
                        'skillInstructions': '😀' * 16385,
                      }),
                    ])
                    as String,
              )
              as Map;
      expect(rejected['status'], isNot('draft_ready'));
      expect(
        (await db.getAllWidgets()).single.spec['pendingVersionDraft'],
        isNull,
      );
      expect(
        (await db.getAllWidgets()).single.spec['skillInstructions'],
        edited,
      );
      await coldRuntime.close();
    },
  );

  test(
    '64 KiB is an exact UTF8 boundary rather than a rune or quality limit',
    () {
      final exact = '😀' * 16384;
      expect(utf8.encode(exact).length, surfaceAgentDocumentMaxUtf8Bytes);
      expect(readSurfaceAgentDocument(exact), exact);
      expect(SurfaceProject.fromJson(payload(exact)).skillInstructions, exact);
      final tooLarge = '$exact😀';
      expect(() => readSurfaceAgentDocument(tooLarge), throwsFormatException);
      expect(
        () => SurfaceProject.fromJson(payload(tooLarge)),
        throwsFormatException,
      );
      expect(
        () => AppletCatalogItem.fromJson(
          catalog(tooLarge),
          trustedOrigin: Uri.parse('https://api.example.test'),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'oversized docs are rejected before a saved widget is created',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'agent-doc-reject.db',
      );
      addTearDown(db.close);
      appServices.put<DBService>(db);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final result =
          jsonDecode(
                await skill.methods['showSurface']!([
                      jsonEncode(payload('x' * 65537)),
                    ])
                    as String,
              )
              as Map;
      expect(result.containsKey('widgetId'), isFalse);
      expect(await db.getAllWidgets(), isEmpty);
      expect(runtime.isVisible.value, isFalse);
    },
  );

  test('edit schema exposes document capacity without shrinking its value', () {
    final skill = FreeformSurfaceSkill(
      agentId: 'self',
      runtime: SurfaceRuntime(),
    );
    final schema = skill.structuredActionPromptSchemas.schemaFor(
      'editSurface',
    )!;
    expect((schema['properties'] as Map)['skillInstructions'], {
      'type': 'string',
      'maxLength': 65536,
    });
  });

  test('manifest instructions keep their independent 4096 rune boundary', () {
    expect(SurfaceManifest.maxInstructionsRunes, 4096);
    final manifest = SurfaceManifest.fromSpec({
      'schemaVersion': 2,
      'events': [],
      'actions': [],
      'instructions': 'x' * 4097,
    });
    expect(
      manifest.diagnoseContract(),
      contains('surface.manifest.instructions_too_long'),
    );
  });

  test(
    'ill-formed Unicode and invalid text controls reject without source prose',
    () {
      for (final document in [
        String.fromCharCode(0xD800),
        'PRIVATE\u0000DOC',
      ]) {
        try {
          readSurfaceAgentDocument(document);
          fail('invalid document must reject');
        } on FormatException catch (error) {
          expect(error.message, 'invalid_skill_instructions');
          expect(error.toString(), isNot(contains('PRIVATE')));
        }
      }
    },
  );
}
