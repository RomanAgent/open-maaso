import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

import 'support/project_source_fixture.dart';

SurfaceProject _project(String js) => SurfaceProject.fromJson({
  'id': 'host-game',
  'title': '完整游戏',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': '<main><canvas></canvas><button>Play</button></main>',
  'js': js,
  'manifest': {'actions': [], 'events': []},
});

String _diagnostic(int offset) =>
    '${SurfaceProjectValidator.javaScriptLexicalFailurePrefix} (UTF-16 offset $offset)';

void main() {
  test('patch rejections have precise closed reasons without source text', () {
    const reasons = {
      'edit_match': SourceDiagnosticReason.exactMatchRejected,
      'edit_overlap': SourceDiagnosticReason.overlapRejected,
      'edit_incomplete': SourceDiagnosticReason.jsonIncomplete,
      'edit_no_progress': SourceDiagnosticReason.stalled,
      'edit_count': SourceDiagnosticReason.invalidValueType,
      'chunk_binding': SourceDiagnosticReason.sourceBindingInvalid,
    };
    for (final entry in reasons.entries) {
      expect(
        sourceProtocolDiagnostic(SourceWorkspaceProtocolException(entry.key)),
        entry.value,
      );
      final diagnostic = SourceGenerationDiagnostic(
        phase: SourceDiagnosticPhase.append,
        reason: entry.value,
      );
      expect(
        SourceGenerationDiagnostic.fromJson(diagnostic.toJson()).reason,
        entry.value,
      );
    }
  });
  test(
    'actual engine handles syntax and browser capabilities after admission',
    () {
      // Some inputs are valid modern JavaScript and some contain real syntax
      // errors. Static admission does not replace the browser parser in either
      // case; runtime diagnostics own actual failure and repair evidence.
      for (final source in [
        "function shoot(){let p={weapon:'L'};if(p(p.weapon==='L'){return 1;}}",
        "function publish(x){};publish({state:'ready'}));",
        'const caption="星😀";\nstart());',
        r'const \u0061 = 1;',
        'fetch("/state");',
        'localStorage.getItem("state");',
        'window.location.href="/next";',
        'eval("start()");',
        'parent.postMessage("state","*");',
        'fetch(',
        sourceJs,
      ]) {
        expect(
          SurfaceProjectValidator.diagnoseForPublicGame(_project(source)),
          isEmpty,
          reason: source,
        );
      }
    },
  );

  test(
    'closed offsets reject raw details, duplicate facts and invalid bounds',
    () {
      expect(
        SurfaceProjectValidator.javaScriptLexicalFailureOffset(_diagnostic(0)),
        0,
      );
      for (final value in [
        '${_diagnostic(3)} PRIVATE_SOURCE',
        _diagnostic(-1),
        _diagnostic(8 * 1024 * 1024 + 1),
        '${_diagnostic(3)}; ${_diagnostic(4)}',
        '${SurfaceProjectValidator.javaScriptLexicalFailurePrefix} (UTF-16 offset 3.0)',
        'SyntaxError: private source',
      ]) {
        expect(
          SurfaceProjectValidator.javaScriptLexicalFailureOffset(value),
          isNull,
          reason: value,
        );
      }
      final public = generatedTaskValidationPublicHint(
        '${_diagnostic(3)}; PRIVATE_SOURCE_OR_STACK',
        zh: true,
      );
      expect(public, contains('旧版网页代码检查记录'));
      expect(public, isNot(contains('正在修复')));
      expect(public, isNot(contains('UTF-16')));
      expect(public, isNot(contains('PRIVATE')));
    },
  );

  test(
    'persisted lexical diagnostics require a bounded integer and matching phase/reason',
    () {
      final valid = SourceGenerationDiagnostic(
        phase: SourceDiagnosticPhase.validation,
        reason: SourceDiagnosticReason.sourceLexicalValidationFailed,
        javascriptUtf16Offset: 42,
      ).toJson();
      expect(
        SourceGenerationDiagnostic.fromJson(valid).javascriptUtf16Offset,
        42,
      );
      for (final map in [
        {...valid, 'javascriptUtf16Offset': null},
        {...valid, 'javascriptUtf16Offset': 42.0},
        {...valid, 'javascriptUtf16Offset': '42'},
        {...valid, 'javascriptUtf16Offset': -1},
        {...valid, 'javascriptUtf16Offset': 8 * 1024 * 1024 + 1},
        {...valid, 'phase': 'append'},
        {...valid, 'reason': 'runtimeFirstFrameRejected'},
        {...valid, 'raw': 'PRIVATE_SOURCE_OR_STACK'},
      ]) {
        expect(
          () => SourceGenerationDiagnostic.fromJson(map),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
    },
  );

  test(
    'producer stores only the closed scanner fact and never diagnostic text',
    () async {
      const instruction = '生成完整游戏';
      final blueprint = SourceBlueprint.fromJson(sourcePlan);
      final draft = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(instruction),
        experienceType: 'game',
        blueprint: blueprint,
        blueprintComplete: true,
        files: [
          for (final plan in blueprint.files)
            SourceFileSnapshot(
              plan: plan,
              complete: true,
              source: switch (plan.kind) {
                SourceFileKind.html => sourceHtml,
                SourceFileKind.css => sourceCss,
                SourceFileKind.js => sourceJs,
              },
            ),
        ],
      );
      final saved = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: instruction,
        surfaceId: 'host-owned',
        zh: true,
        initialDraft: draft,
        onDraft: saved.add,
      );
      await producer.generate();
      await producer.recordValidationDiagnostic(
        diagnostic: '${_diagnostic(42)}; PRIVATE_SOURCE_OR_STACK',
      );
      expect(saved.last.diagnostic!.toJson(), {
        'phase': 'validation',
        'reason': 'sourceLexicalValidationFailed',
        'javascriptUtf16Offset': 42,
      });
      expect(
        SourceWorkspaceSnapshot.fromJson(
          saved.last.toJson(),
        ).diagnostic!.javascriptUtf16Offset,
        42,
      );
      expect(
        saved.last.files.map((f) => f.source),
        draft.files.map((f) => f.source),
      );
      expect(client.requests, isEmpty);
    },
  );
}
