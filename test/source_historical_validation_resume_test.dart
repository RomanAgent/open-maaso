import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

import 'support/project_source_fixture.dart';

const _requirement = 'Preserve my complete original game and every control.';
String _diagnostic(String name, int offset) =>
    '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
    '(rule reservedIdentifier, name $name, UTF-16 offset $offset); '
    'public webApps must not use network, storage, dynamic code, navigation, or cross-frame APIs';

SourceWorkspaceSnapshot _draft(
  String prefix,
  String previous,
  String diagnostic,
) {
  final blueprint = SourceBlueprint.fromJson(sourcePlan);
  final fact = SurfaceProjectValidator.javaScriptRestrictionFact(diagnostic);
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(_requirement),
    experienceType: 'game',
    blueprint: blueprint,
    blueprintComplete: true,
    activeFileId: 'game.js',
    diagnostic: fact == null
        ? SourceGenerationDiagnostic(
            phase: SourceDiagnosticPhase.validation,
            reason: SourceDiagnosticReason.runtimeFirstFrameRejected,
            fileId: 'game.js',
          )
        : SourceGenerationDiagnostic(
            phase: SourceDiagnosticPhase.validation,
            reason: SourceDiagnosticReason.sourceCapabilityValidationFailed,
            fileId: 'game.js',
            javascriptUtf16Offset: fact.utf16Offset,
            javascriptRestrictionRule: fact.rule.name,
            javascriptOffendingName: fact.offendingName,
          ),
    files: [
      SourceFileSnapshot(
        plan: blueprint.files[0],
        source: sourceHtml,
        complete: true,
      ),
      SourceFileSnapshot(
        plan: blueprint.files[1],
        source: sourceCss,
        complete: true,
      ),
      SourceFileSnapshot(
        plan: blueprint.files[2],
        source: prefix,
        previousSource: previous,
        repairDiagnostic: diagnostic,
        chunkDigests: [sourceWorkspaceDigest(prefix)],
      ),
    ],
  );
}

GeneratedGameArtifact _producer(
  SourceFixtureClient client, {
  SourceWorkspaceSnapshot? initial,
  List<SourceWorkspaceSnapshot>? drafts,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'resume-policy-owned',
  zh: false,
  initialDraft: initial,
  onDraft: drafts?.add,
);

void main() {
  test(
    'legacy whole-this rejection clears only after current complete-candidate checks',
    () async {
      const prefix =
          '$sourceJs\nfunction Actor(){this.x=0;}'
          'Actor.prototype.step=function(){return ';
      const suffix = 'this;};const actor=new Actor();actor.step();';
      const previous = '$prefix$suffix';
      final diagnostic = _diagnostic(
        'this',
        previous.indexOf('return this') + 7,
      );
      final initial = _draft(prefix, previous, diagnostic);
      final untouched = jsonEncode(initial.toJson());
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      final result = await _producer(
        client,
        initial: initial,
        drafts: drafts,
      ).generate();
      expect(client.requests, hasLength(1));
      expect(client.requests.single.last.content, _requirement);
      final prompt = client.requests.single.first.content;
      expect(prompt, contains('"baseCursor":${utf8.encode(prefix).length}'));
      expect(prompt, isNot(contains(diagnostic)));
      expect(prompt, isNot(contains('Historical host validation diagnostic')));
      expect(prompt, contains(jsonEncode(previous)));
      final cleared = drafts
          .firstWhere(
            (draft) =>
                draft.files
                    .singleWhere((file) => file.plan.id == 'game.js')
                    .repairDiagnostic ==
                null,
          )
          .files
          .singleWhere((file) => file.plan.id == 'game.js');
      expect(cleared.source, prefix);
      expect(cleared.cursor, utf8.encode(prefix).length);
      expect(cleared.previousSource, previous);
      expect(cleared.complete, isFalse);
      expect(cleared.chunkDigests, initial.files.last.chunkDigests);
      final completed = drafts.last.files.singleWhere(
        (file) => file.plan.id == 'game.js',
      );
      expect(completed.source, previous);
      expect(completed.previousSource, previous);
      expect(completed.repairDiagnostic, isNull);
      expect(drafts.last.diagnostic, isNull);
      expect(jsonEncode(initial.toJson()), untouched);
      SurfaceProjectValidator.validateForPublicGame(
        SurfaceProject.fromJson(result.actions.single['surface'] as Map),
      );
    },
  );

  test(
    'an earlier observed runtime failure remains until a fresh host execution',
    () async {
      const prefix = '$sourceJs\nconst repaired=', suffix = 'true;';
      const previous = '$sourceJs\nmissingOwner();';
      const diagnostic = 'surface worker first frame rejected: runtime_failed';
      final initial = _draft(prefix, previous, diagnostic);
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      await _producer(client, initial: initial, drafts: drafts).generate();
      final prompt = client.requests.single.first.content;
      expect(
        prompt,
        contains(
          'Historical host validation diagnostic for an earlier complete candidate:',
        ),
      );
      expect(prompt, contains(jsonEncode(diagnostic)));
      expect(
        prompt,
        contains('current partial source has not been revalidated'),
      );
      expect(
        prompt,
        contains('current authoring policy above takes precedence'),
      );
      expect(prompt, contains('"baseCursor":${utf8.encode(prefix).length}'));
      final completed = drafts.last.files.singleWhere(
        (file) => file.plan.id == 'game.js',
      );
      expect(completed.source, '$prefix$suffix');
      expect(completed.previousSource, previous);
      expect(completed.repairDiagnostic, diagnostic);
      expect(
        drafts.last.diagnostic?.reason,
        SourceDiagnosticReason.runtimeFirstFrameRejected,
      );
    },
  );

  test(
    'runtime first-frame failures are not cleared by static source checks',
    () async {
      const prefix = '$sourceJs\nconst retained=', suffix = 'true;';
      const diagnostic = 'surface worker first frame rejected: runtime_failed';
      final initial = _draft(prefix, sourceJs, diagnostic);
      final client = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      await _producer(client, initial: initial).generate();
      expect(
        client.requests.single.first.content,
        contains(jsonEncode(diagnostic)),
      );
      expect(
        client.requests.single.first.content,
        contains('current partial source has not been revalidated'),
      );
    },
  );

  test(
    'planning and HTML authoring consistently retain supported inline source',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      await _producer(client).generate();
      final planning = client.requests.first.first.content;
      final markup = client.requests[1].first.content;
      for (final source in [planning, markup]) {
        final prompt = source.replaceAll(RegExp(r'\s+'), ' ');
        expect(prompt.toLowerCase(), contains('classic inline'));
        expect(prompt, isNot(contains('cannot be used to deliver inline')));
        expect(prompt, isNot(contains('Do not embed style or script content')));
        expect(prompt, contains('only copy'));
        expect(
          prompt,
          contains(
            'External resources and ordinary browser APIs are permitted',
          ),
        );
        expect(
          prompt,
          isNot(contains('Do not use reserved browser names such as top')),
        );
      }
    },
  );
}
