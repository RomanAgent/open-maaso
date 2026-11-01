import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() => appServices.testMode = true);
  tearDown(appServices.reset);

  test('new authored sources are not restyled by the host', () {
    for (final experience in ['game', 'utility']) {
      final source = <String, Object?>{
        ..._source(),
        'experienceType': experience,
      };
      final before = jsonEncode(source);
      SurfaceAuthoringTheme.applyToNewSource(source);
      expect(jsonEncode(source), before);
      SurfaceAuthoringTheme.applyToNewSource(source);
      expect(jsonEncode(source), before);
    }
  });

  test('external and custom CSS passes through the theme seam unchanged', () {
    const authored =
        '@import url("https://example.com/retro.css");'
        'body{background:#120024;color:#f6e044}'
        'button{border:3px solid #ff00aa;border-radius:0;min-height:24px}';
    final source = <String, Object?>{
      ..._source(),
      'rendering': 'webApp',
      'css': authored,
    };
    SurfaceAuthoringTheme.applyToNewSource(source);
    expect(source['css'], authored);
    expect(source['css'], isNot(contains(MaasoFrostTokens.themeId)));
  });

  test('built-in surfaces can still explicitly use a legacy snapshot', () {
    final css = SurfaceAuthoringTheme.cssSnapshot();
    expect(css, startsWith(SurfaceAuthoringTheme.snapshotStart));
    expect(css, contains('--maaso-theme-id:"${MaasoFrostTokens.themeId}"'));
    expect(css, contains('--maaso-canvas:#FFFFFF;'));
    expect(css, contains('--maaso-action:#3B6DE4;'));
    final source = <String, Object?>{..._source(), 'css': css};
    SurfaceAuthoringTheme.applyToNewSource(source);
    expect(source['css'], css);
  });

  test('public webApp theme preparation keeps the authored CSS', () {
    final source = <String, Object?>{
      ..._source(),
      'experienceType': 'game',
      'rendering': 'webApp',
      'html': '<main><button id="start">Play</button></main>',
      'js':
          "document.querySelector('#start').addEventListener('click', function(){document.body.dataset.started='true';});",
    };
    final css = source['css'];
    SurfaceAuthoringTheme.applyToNewSource(source);
    expect(source['css'], css);
    expect(
      SurfaceProjectValidator.diagnoseForPublicGame(
        SurfaceProject.fromJson(source),
      ),
      isEmpty,
    );
  });

  test('workerCanvas content and empty CSS remain byte-for-byte intact', () {
    final source = <String, Object?>{
      ..._source(),
      'rendering': 'workerCanvas',
      'html': '',
      'css': '',
      'js': 'Game.define({});',
    };
    final before = jsonEncode(source);
    SurfaceAuthoringTheme.applyToNewSource(source);
    expect(jsonEncode(source), before);
  });

  test('an explicit CSS edit can replace or remove an old snapshot', () {
    final previous =
        '${SurfaceAuthoringTheme.cssSnapshot()}\n${_source()['css']}';
    const artwork = '  body{background:#171717;color:#fefefe}';
    expect(
      SurfaceAuthoringTheme.preserveSnapshot(
        previous,
        artwork,
        transparent: true,
      ),
      artwork,
    );
    expect(SurfaceAuthoringTheme.preserveSnapshot(previous, ''), '');
    expect(
      SurfaceAuthoringTheme.preserveSnapshot(
        previous,
        previous,
        transparent: true,
      ),
      previous,
      reason:
          'An explicitly retained snapshot is source data, not a host restyling request',
    );
    expect(
      SurfaceAuthoringTheme.preserveSnapshot('body{color:red}', artwork),
      artwork,
    );
  });

  test('authored CSS survives save, edit, revert and reopen', () async {
    final db = await _database();
    appServices.put<DBService>(db);
    final runtime = SurfaceRuntime();
    final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
    final result =
        jsonDecode(await skill.methods['showSurface']!([_source()]) as String)
            as Map;
    expect(result['error'], isNull);
    final id = result['surfaceId'];
    final originalCss = runtime.activeProject.value!.css;
    expect(originalCss, _source()['css']);
    expect((await db.getAllWidgets()).single.spec['css'], originalCss);

    final originalWidget = (await db.getAllWidgets()).single;
    final originalVersion = SurfaceVersionHistory.read(
      originalWidget.spec,
      title: originalWidget.title,
    ).current.id;
    final edit =
        jsonDecode(
              await skill.methods['editSurface']!([
                    {
                      'surfaceId': id,
                      'css': 'body{background:#141414;color:#ffffff}',
                    },
                  ])
                  as String,
            )
            as Map<String, dynamic>;
    expect(edit['status'], 'draft_ready');
    expect(runtime.activeProject.value!.css, originalCss);
    final pendingWidget = (await db.getAllWidgets()).single;
    final draft = SurfaceVersionDraft.tryParse(
      pendingWidget.spec['pendingVersionDraft'],
    )!;
    expect(draft.source['css'], 'body{background:#141414;color:#ffffff}');
    expect(
      draft.source['css'],
      endsWith('body{background:#141414;color:#ffffff}'),
    );
    await applyAppletVersionDraft(
      item: pendingWidget,
      draftId: edit['draftId'] as String,
      scopeKey: AppletLocalOwnership.currentScopeKey(),
      firstFrameReady: true,
    );
    await skill.methods['reopenSurface']!([
      {'surfaceId': id},
    ]);
    expect(
      runtime.activeProject.value!.css,
      endsWith('body{background:#141414;color:#ffffff}'),
    );
    await skill.methods['revertSurface']!([
      {'surfaceId': id, 'revisionId': originalVersion},
    ]);
    expect(runtime.activeProject.value!.css, originalCss);

    final freshRuntime = SurfaceRuntime();
    final freshSkill = FreeformSurfaceSkill(
      agentId: 'self',
      runtime: freshRuntime,
    );
    await freshSkill.methods['reopenSurface']!([
      {'surfaceId': id},
    ]);
    expect(freshRuntime.activeProject.value!.css, originalCss);
    expect(freshRuntime.document.value, contains(originalCss));
  });

  test(
    'legacy saved Surface is reopened without theme or source changes',
    () async {
      final db = await _database();
      appServices.put<DBService>(db);
      const legacyCss = 'body{background:#221100;color:#ffddee}';
      final widget = AgentWidget(
        agentId: 'self',
        title: 'Existing custom artwork',
        kind: 'surface',
        spec: <String, Object?>{
          ..._source(),
          'surfaceId': 'legacy-artwork',
          'surfaceKind': 'card',
          'css': legacyCss,
        },
        createdAt: DateTime.utc(2026, 1, 1),
      );
      AppletLocalOwnership.stamp(widget);
      await db.saveAgentWidget(widget);
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);
      final result =
          jsonDecode(
                await skill.methods['reopenSurface']!([
                      {'surfaceId': 'legacy-artwork'},
                    ])
                    as String,
              )
              as Map;
      expect(result['error'], isNull);
      expect(runtime.activeProject.value!.css, legacyCss);
      expect((await db.getAllWidgets()).single.spec['css'], legacyCss);
      expect(runtime.document.value, isNot(contains(MaasoFrostTokens.themeId)));
    },
  );

  test('JSON surface.show creation uses the same theme as the skill', () async {
    final runtime = SurfaceRuntime();
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: SkillCatalog.all,
      enabledSkillIds: const {'freeform_surface'},
    );
    final grant = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: <SkillDescriptor>[
          registry.descriptorFor('FreeformSurface')!,
        ],
        maxSkills: 1,
        promptBudget: 4096,
      ),
    );
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    final executor = AgentActionExecutor(
      agentId: 'self',
      locale: AppLocale.en,
      skillManager: SkillManager()..registerSkill(grant.activatedSkills.single),
      surfaceRuntime: runtime,
      expectedAppletScopeKey: scopeKey,
      surfaceExecutionGrant: SurfaceExecutionGrant.issue(
        executableHostGrant: grant,
        agentId: 'self',
        appletScopeKey: scopeKey,
        experienceType: SurfaceExperienceType.utility,
      ),
      speak: (_) async {},
    );
    final envelope = AgentActionEnvelope.parse(
      jsonEncode({
        'reply': '',
        'actions': [
          {'type': 'surface.show', 'surface': _source()},
        ],
      }),
    );
    executor.preflightSurfaceActions(envelope);
    expect(runtime.isVisible.value, isFalse);
    final result = await executor.execute(envelope);
    expect(result.errors, isEmpty);
    expect(runtime.activeProject.value!.css, _source()['css']);
  });

  test(
    'full and compact authoring prompts preserve creative freedom in both locales',
    () {
      for (final locale in [AppLocale.en, AppLocale.zh]) {
        for (final key in [
          'runtime.skills.surface_authoring',
          'runtime.section.surface_compact',
        ]) {
          final prompt = AgentPromptCatalog.text(key, locale: locale);
          expect(prompt, isNot(contains(MaasoFrostTokens.themeId)));
          expect(prompt, isNot(contains('maaso-input')));
          expect(prompt, contains('JavaScript'));
          expect(prompt, contains(locale == AppLocale.en ? 'external' : '外部'));
          expect(prompt, contains('workerCanvas'));
        }
      }
    },
  );
}

Map<String, Object?> _source() => {
  'id': 'test-surface',
  'title': 'Offline notes',
  'kind': 'card',
  'experienceType': 'utility',
  'rendering': 'dom',
  'html': '<main><h1>My notes</h1><p>Time for a walk.</p></main>',
  'css': 'main{padding:20px}',
  'js': '',
  'transparent': false,
  'manifest': <String, Object?>{},
};

Future<DBService> _database() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'surface_theme_${DateTime.now().microsecondsSinceEpoch}.db',
);
