import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

import 'support/project_source_fixture.dart';

SurfaceProject _project(String js) => SurfaceProject.fromJson({
  'id': 'host',
  'title': 'Game',
  'kind': 'fullscreen',
  'rendering': 'webApp',
  'experienceType': 'game',
  'html': sourceHtml,
  'js': js,
  'manifest': {'actions': [], 'events': []},
});
SurfaceJavaScriptRestrictionFact _historicalFact(
  String rule,
  String name,
  int offset,
) => SurfaceProjectValidator.javaScriptRestrictionFact(
  '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
  '(rule $rule, name $name, UTF-16 offset $offset)',
)!;

void main() {
  test('retired policy facts never reject current browser source', () {
    for (final source in [
      'const top="#222";',
      'var W=window;var utility=Object;',
      'document.getElementById("lives").innerHTML="星😀";',
      'fetch("/state");localStorage.getItem("score");',
    ]) {
      final issues = SurfaceProjectValidator.diagnoseForPublicGame(
        _project(source),
      );
      expect(issues, isEmpty, reason: source);
      expect(
        SurfaceProjectValidator.javaScriptRestrictionFact(issues.join('; ')),
        isNull,
      );
    }
  });

  test(
    'closed evidence parser rejects private names, strings, invalid rule and bounds',
    () {
      final fact = _historicalFact('reservedIdentifier', 'top', 6);
      for (final invalid in [
        fact.diagnostic.replaceFirst('top', 'PRIVATE_SECRET'),
        fact.diagnostic.replaceFirst('reservedIdentifier', 'model supplied'),
        fact.diagnostic.replaceFirst('offset 6', 'offset -1'),
        '${fact.diagnostic} PRIVATE_STACK',
        '${fact.diagnostic}; ${fact.diagnostic}',
        '${SurfaceProjectValidator.javaScriptRestrictionPrefix} (rule reservedIdentifier, name top, UTF-16 offset 8388609)',
      ]) {
        expect(
          SurfaceProjectValidator.javaScriptRestrictionFact(invalid),
          isNull,
          reason: invalid,
        );
      }
    },
  );

  test(
    'snapshot permits only matching closed rule/name/reason and bounded integer offsets',
    () {
      final fact = _historicalFact('forbiddenMember', 'innerHTML', 49);
      final data = SourceGenerationDiagnostic(
        phase: SourceDiagnosticPhase.validation,
        reason: SourceDiagnosticReason.sourceCapabilityValidationFailed,
        javascriptUtf16Offset: fact.utf16Offset,
        javascriptRestrictionRule: fact.rule.name,
        javascriptOffendingName: fact.offendingName,
      ).toJson();
      expect(
        SourceGenerationDiagnostic.fromJson(data).javascriptOffendingName,
        'innerHTML',
      );
      for (final invalid in [
        {...data, 'javascriptOffendingName': 'PRIVATE_SECRET'},
        {...data, 'javascriptRestrictionRule': 'permission'},
        {...data, 'javascriptUtf16Offset': 3.0},
        {...data, 'javascriptUtf16Offset': null},
        {...data, 'reason': 'validationRejected'},
        {...data, 'phase': 'append'},
        {...data, 'rawStack': 'PRIVATE_SECRET'},
      ]) {
        expect(
          () => SourceGenerationDiagnostic.fromJson(invalid),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
    },
  );

  test(
    'producer records precise host facts without raw diagnostics or changing source',
    () async {
      const instruction = '完整游戏';
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
      final producer = GeneratedGameArtifact(
        client: SourceFixtureClient([]),
        instruction: instruction,
        surfaceId: 'host',
        zh: true,
        initialDraft: draft,
        onDraft: saved.add,
      );
      await producer.generate();
      final fact = _historicalFact('reservedIdentifier', 'top', 6);
      await producer.recordValidationDiagnostic(
        diagnostic: '${fact.diagnostic}; PRIVATE_STACK',
      );
      expect(saved.last.diagnostic!.toJson(), {
        'phase': 'validation',
        'reason': 'sourceCapabilityValidationFailed',
        'javascriptUtf16Offset': fact.utf16Offset,
        'javascriptRestrictionRule': 'reservedIdentifier',
        'javascriptOffendingName': 'top',
      });
      expect(
        saved.last.files.map((f) => f.source),
        draft.files.map((f) => f.source),
      );
    },
  );
}
