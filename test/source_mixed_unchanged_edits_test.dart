import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_edits.dart';
import 'support/project_source_fixture.dart';

SourceFileSnapshot _file(String source) => SourceFileSnapshot(
  plan: SourceFilePlan(
    id: 'game.js',
    kind: SourceFileKind.js,
    purpose: 'Original',
  ),
  source: source,
  complete: true,
);
String _wire(String source, List<Map<String, Object?>> edits) => jsonEncode({
  'fileId': 'game.js',
  'baseHash': sourceWorkspaceDigest(source),
  'edits': edits,
});
SourceFileEdits _decode(String source, List<Map<String, Object?>> edits) =>
    SourceFileEdits.decode(
      _wire(source, edits),
      file: _file(source),
      knownLength: false,
    );

void main() {
  test(
    'a legally bound unchanged span is omitted only beside a real modification',
    () {
      const source = 'A B C';
      final batch = _decode(source, [
        {'oldText': 'A', 'newText': 'A'},
        {'oldText': 'C', 'newText': 'Z'},
      ]);
      expect(batch.apply(_file(source)), 'A B Z');
      expect(batch.omittedEditIndices, [0]);
    },
  );
  for (final unchanged in [
    {'oldText': 'missing', 'newText': 'missing'},
    {'oldText': 'A', 'newText': 'A', 'startUtf16': -1},
    {'oldText': 'A', 'newText': 'A', 'startUtf16': 2},
    {'oldText': 'A', 'newText': 'A', 'startUtf16': true},
  ]) {
    test('fake unchanged binding cannot be omitted: $unchanged', () {
      final file = _file('A B C');
      expect(
        () => _decode(file.source, [
          unchanged,
          {'oldText': 'C', 'newText': 'Z'},
        ]).apply(file),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
      expect(file.source, 'A B C');
    });
  }
  test(
    'an ambiguous unchanged span still needs an explicit original position',
    () {
      const source = 'A A C';
      expect(
        () => _decode(source, [
          {'oldText': 'A', 'newText': 'A'},
          {'oldText': 'C', 'newText': 'Z'},
        ]).apply(_file(source)),
        throwsA(isA<SourceFileEditRejection>()),
      );
      expect(
        _decode(source, [
          {'oldText': 'A', 'newText': 'A', 'startUtf16': 0},
          {'oldText': 'C', 'newText': 'Z'},
        ]).apply(_file(source)),
        'A A Z',
      );
    },
  );
  test(
    'unchanged overlap and stale hash reject the entire meaningful batch',
    () {
      const source = 'ABCDE';
      expect(
        () => _decode(source, [
          {'oldText': 'ABC', 'newText': 'ABC'},
          {'oldText': 'BC', 'newText': 'Z'},
        ]).apply(_file(source)),
        throwsA(
          isA<SourceWorkspaceProtocolException>().having(
            (e) => e.code,
            'code',
            'edit_overlap',
          ),
        ),
      );
      final batch = _decode(source, [
        {'oldText': 'A', 'newText': 'A'},
        {'oldText': 'E', 'newText': 'Z'},
      ]);
      expect(
        () => batch.apply(_file('ABCDE changed')),
        throwsA(
          isA<SourceWorkspaceProtocolException>().having(
            (e) => e.code,
            'code',
            'chunk_binding',
          ),
        ),
      );
    },
  );
  test(
    'all unchanged spans still require valid source and remain no-progress',
    () {
      expect(
        () => _decode('A', [
          {'oldText': 'A', 'newText': 'A'},
        ]),
        throwsA(
          isA<SourceWorkspaceProtocolException>().having(
            (e) => e.code,
            'code',
            'edit_no_progress',
          ),
        ),
      );
      expect(
        () => _decode('A', [
          {'oldText': 'fake', 'newText': 'fake'},
        ]),
        throwsA(
          isA<SourceWorkspaceProtocolException>().having(
            (e) => e.code,
            'code',
            'edit_match',
          ),
        ),
      );
    },
  );
  test(
    'pure unchanged repair keeps the last complete validation cause while showing delivery progress',
    () async {
      const source = 'function pass(){return this;}';
      final wire = _wire(source, [
        {'oldText': 'return this;', 'newText': 'return this;'},
      ]);
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: source),
        wire,
        wire,
        wire,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[], publicSteps = <String>[];
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: 'All original rules',
        surfaceId: 'owned',
        zh: true,
        onDraft: drafts.add,
        onCheckpoint: (step, {publicSummary}) {
          if (publicSummary != null) publicSteps.add(publicSummary);
        },
      );
      final original = await producer.generate();
      await producer.recordValidationDiagnostic(
        diagnostic:
            '${SurfaceProjectValidator.javaScriptRestrictionPrefix} (rule reservedIdentifier, name this, UTF-16 offset 23)',
      );
      await expectLater(
        producer.repair(
          original,
          '${SurfaceProjectValidator.javaScriptRestrictionPrefix} (rule reservedIdentifier, name this, UTF-16 offset 23)',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(drafts.last.diagnostic!.phase, SourceDiagnosticPhase.validation);
      expect(
        drafts.last.diagnostic!.reason,
        SourceDiagnosticReason.sourceCapabilityValidationFailed,
      );
      expect(drafts.last.diagnostic!.javascriptOffendingName, 'this');
      expect(publicSteps.any((step) => step.contains('没有改变源码')), isTrue);
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .source,
        source,
      );
    },
  );
}
