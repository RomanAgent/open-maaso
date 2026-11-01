import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_edits.dart';
import 'support/project_source_fixture.dart';

SourceFileSnapshot _file(String source) => SourceFileSnapshot(
  plan: SourceFilePlan(
    id: 'game.js',
    kind: SourceFileKind.js,
    purpose: 'Original source',
  ),
  source: source,
  complete: true,
);
String _wire(String source, List<Map<String, Object?>> edits) => jsonEncode({
  'fileId': 'game.js',
  'baseHash': sourceWorkspaceDigest(source),
  'edits': edits,
});
Map<String, Object?> _edit(String oldText, String newText, {Object? start}) => {
  'oldText': oldText,
  'newText': newText,
  'startUtf16': ?start,
};
SourceFileEdits _decode(String source, List<Map<String, Object?>> edits) =>
    SourceFileEdits.decode(
      _wire(source, edits),
      file: _file(source),
      knownLength: false,
    );

void main() {
  test('an explicit offset edits only the selected repeated original span', () {
    const source = 'same same same';
    final file = _file(source);
    expect(
      _decode(source, [_edit('same', 'fixed', start: 5)]).apply(file),
      'same fixed same',
    );
    expect(file.source, source);
    expect(
      () => _decode(source, [_edit('same', 'fixed')]).apply(file),
      throwsA(
        isA<SourceFileEditRejection>().having(
          (e) => e.facts.single.toJson(),
          'facts',
          {'editIndex': 0, 'reason': 'ambiguousMatch', 'matchCount': 3},
        ),
      ),
    );
  });
  test('offsets are UTF16, not bytes, and preserve surrogate pairs', () {
    const source = '🚀😀 same same';
    final start = source.lastIndexOf('same');
    expect(
      _decode(source, [
        _edit('same', 'fixed', start: start),
      ]).apply(_file(source)),
      '🚀😀 same fixed',
    );
    expect(
      () => _decode(source, [_edit('😀', 'x', start: 1)]).apply(_file(source)),
      throwsA(
        isA<SourceFileEditRejection>().having(
          (e) => e.facts.single.reason,
          'reason',
          SourceEditRejectionReason.invalidOffset,
        ),
      ),
    );
  });
  for (final start in [-1, 100, 1.5, true, '0']) {
    test('invalid offset $start is rejected rather than relocated', () {
      expect(
        () => _decode('same same', [
          _edit('same', 'fixed', start: start),
        ]).apply(_file('same same')),
        throwsA(
          isA<SourceFileEditRejection>().having(
            (e) => e.facts.single.reason,
            'reason',
            SourceEditRejectionReason.invalidOffset,
          ),
        ),
      );
    });
  }
  test('wrong text at a valid offset never chooses another occurrence', () {
    expect(
      () => _decode('same same', [
        _edit('same', 'fixed', start: 1),
      ]).apply(_file('same same')),
      throwsA(
        isA<SourceFileEditRejection>().having(
          (e) => e.facts.single.toJson(),
          'facts',
          {'editIndex': 0, 'reason': 'noMatch', 'matchCount': 0},
        ),
      ),
    );
  });
  test(
    'mixed offset and unique edits share one original source and reject overlaps atomically',
    () {
      const source = 'same same unique';
      final file = _file(source);
      expect(
        _decode(source, [
          _edit('same', 'replacement', start: 5),
          _edit('unique', 'end'),
        ]).apply(file),
        'same replacement end',
      );
      expect(
        () => _decode(source, [
          _edit('same same', 'x', start: 0),
          _edit('same', 'y', start: 5),
        ]).apply(file),
        throwsA(
          isA<SourceFileEditRejection>().having(
            (e) => e.code,
            'code',
            'edit_overlap',
          ),
        ),
      );
      expect(file.source, source);
    },
  );
  test('a stale hash cannot authorize even a valid indexed substring', () {
    final batch = _decode('same same', [_edit('same', 'fixed', start: 5)]);
    expect(
      () => batch.apply(_file('same same changed')),
      throwsA(
        isA<SourceWorkspaceProtocolException>().having(
          (e) => e.code,
          'code',
          'chunk_binding',
        ),
      ),
    );
  });
  test(
    'one rejected batch reports every ambiguous, absent and noop edit without mutation',
    () {
      const source = 'same same unique';
      final file = _file(source);
      expect(
        () => _decode(source, [
          _edit('same', 'fixed'),
          _edit('missing', 'x'),
          _edit('unique', 'unique'),
        ]).apply(file),
        throwsA(
          isA<SourceFileEditRejection>().having(
            (e) => e.facts.map((f) => f.toJson()).toList(),
            'facts',
            [
              {'editIndex': 0, 'reason': 'ambiguousMatch', 'matchCount': 2},
              {'editIndex': 1, 'reason': 'noMatch', 'matchCount': 0},
            ],
          ),
        ),
      );
      expect(file.source, source);
    },
  );
  test(
    'producer reports match counts and accepts the exact original position on retry',
    () async {
      const source =
          'function first(){return this;}\nfunction second(){return this;}';
      final start = source.indexOf('return this;');
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: source),
        _wire(source, [_edit('return this;', 'return {x:this.x};')]),
        _wire(source, [
          _edit('return this;', 'return {x:this.x};', start: start),
        ]),
      ]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: 'Preserve complete original project',
        surfaceId: 'owned',
        zh: true,
      );
      final before = await producer.generate();
      final after = await producer.repair(
        before,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(6));
      final feedback = client.requests.last.first.content;
      expect(
        feedback,
        contains('"editIndex":0,"reason":"ambiguousMatch","matchCount":2'),
      );
      expect(feedback, contains('startUtf16:integer'));
      expect(feedback, contains('never guess an occurrence'));
      expect(
        (after.actions.single['surface'] as Map)['js'],
        source.replaceFirst('return this;', 'return {x:this.x};'),
      );
      expect(after.reply, before.reply);
      expect(
        client.requests.every(
          (m) => m.last.content == 'Preserve complete original project',
        ),
        isTrue,
      );
    },
  );
}
