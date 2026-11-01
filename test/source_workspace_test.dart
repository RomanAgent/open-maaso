import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

final _plan = SourceFilePlan(
  id: 'logic',
  kind: SourceFileKind.js,
  purpose: 'Complete gameplay',
);
SourceFileSnapshot get _file => SourceFileSnapshot(plan: _plan);
String _prefix(String suffix) =>
    '{"fileId":"logic","baseCursor":0,"prefixHash":"${_file.prefixHash}","append":"$suffix';

void main() {
  test(
    'a fully received unknown field key is rejected even when its value is cut off',
    () {
      final raw = '${_prefix('ok')}","actions":';
      expect(
        () => SourceChunk.decode(raw, knownLength: true, file: _file),
        throwsA(
          isA<SourceWorkspaceProtocolException>().having(
            (e) => e.code,
            'code',
            'fields',
          ),
        ),
      );
    },
  );
  test(
    'restored files reject noninteger cursors and replacement-encoded Unicode',
    () {
      final base = SourceFileSnapshot(plan: _plan, source: 'abc').toJson();
      for (final json in [
        {...base, 'cursor': 3.0},
        {...base, 'source': String.fromCharCode(0xD800), 'cursor': 3},
        {...base, 'previousSource': String.fromCharCode(0xD800)},
      ]) {
        expect(
          () => SourceFileSnapshot.fromJson(json),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
    },
  );
  test(
    'known length decodes complete escaped characters without guessing JSON closure',
    () {
      final encoded = jsonEncode('const label="星\n');
      final raw = encoded.substring(1, encoded.length - 1) + r'\uD83D\uD';
      final chunk = SourceChunk.decode(
        _prefix(raw),
        knownLength: true,
        file: _file,
      );
      expect(chunk.append, 'const label="星\n');
      expect(chunk.done, isFalse);
    },
  );
  test(
    'surrogate pairs, escaped slash, quote and backslash retain exact source',
    () {
      final raw = '${_prefix(r'\uD83D\uDE00\/\\\"')}","done":true}';
      final chunk = SourceChunk.decode(raw, knownLength: false, file: _file);
      expect(chunk.append, '😀/\\"');
      expect(chunk.done, isTrue);
    },
  );
  test(
    'a complete chunk on a known-length receipt remains an unfinished draft',
    () {
      final raw = jsonEncode({
        'fileId': 'logic',
        'baseCursor': 0,
        'prefixHash': _file.prefixHash,
        'append': 'const x=1;',
        'done': true,
      });
      expect(
        SourceChunk.decode(raw, knownLength: true, file: _file).done,
        isFalse,
      );
    },
  );
  test('bindings must be complete before any partial append is admitted', () {
    for (final raw in [
      '{"append":"evil',
      '{"fileId":"logic","baseCursor":0,"append":"evil',
    ]) {
      expect(
        () => SourceChunk.decode(raw, knownLength: true, file: _file),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
    }
  });
  test(
    'cursor, hash, file identity, duplicate keys and authority fields are rejected',
    () {
      final base = {
        'fileId': 'logic',
        'baseCursor': 0,
        'prefixHash': _file.prefixHash,
        'append': 'const x=1;',
        'done': true,
      };
      for (final map in [
        {...base, 'fileId': 'foreign'},
        {...base, 'baseCursor': 1},
        {...base, 'baseCursor': 0.0},
        {...base, 'prefixHash': 'bad'},
        {...base, 'actions': []},
      ]) {
        expect(
          () => SourceChunk.decode(
            jsonEncode(map),
            knownLength: false,
            file: _file,
          ),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
      expect(
        () => SourceChunk.decode(
          '${_prefix('x')}","fileId":"logic","done":true}',
          knownLength: false,
          file: _file,
        ),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
    },
  );
  test(
    'fences, prose, mixed executables and malformed escapes are never repaired locally',
    () {
      for (final raw in [
        '```json\n{}\n```',
        'prefix {}',
        '{};doSomething()',
        _prefix(r'bad\x'),
      ]) {
        expect(
          () => SourceJsonPrefixDecoder(raw).decode(),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
    },
  );
  test(
    'incomplete file definitions are discarded while complete plan entries survive',
    () {
      const text =
          '{"title":"Game","summary":"Full","skillInstructions":"Play","files":[{"id":"page","kind":"html","purpose":"All pages"},{"id":"logic","kind":"js","purpose":"unfinished';
      final prefix = SourceJsonPrefixDecoder(text).decode();
      final plan = SourceBlueprint.fromJson(prefix.values, partial: true);
      expect(plan.files.map((f) => f.id), ['page']);
      expect(prefix.complete, isFalse);
    },
  );
  test('finite file plans reject cycles and unknown dependencies', () {
    for (final files in [
      [
        SourceFilePlan(
          id: 'page',
          kind: SourceFileKind.html,
          purpose: 'Page',
          dependsOn: ['missing'],
        ),
        _plan,
      ],
      [
        SourceFilePlan(
          id: 'page',
          kind: SourceFileKind.html,
          purpose: 'Page',
          dependsOn: ['logic'],
        ),
        SourceFilePlan(
          id: 'logic',
          kind: SourceFileKind.js,
          purpose: 'Game',
          dependsOn: ['page'],
        ),
      ],
    ]) {
      expect(
        () => SourceBlueprint(
          title: 'Game',
          summary: 'Full',
          skillInstructions: 'Play',
          files: files,
        ).orderedFiles(),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
    }
  });
  test(
    'snapshot roundtrip preserves UTF8 cursor and the original completed repair source',
    () {
      final blueprint = SourceBlueprint(
        title: 'Game',
        summary: 'Full',
        skillInstructions: 'Play',
        files: [
          SourceFilePlan(
            id: 'page',
            kind: SourceFileKind.html,
            purpose: 'Page',
          ),
          _plan,
        ],
      );
      final snapshot = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest('full requirement'),
        experienceType: 'game',
        blueprint: blueprint,
        blueprintComplete: true,
        files: [
          SourceFileSnapshot(
            plan: _plan,
            source: '星😀',
            previousSource: 'original',
            repairDiagnostic: 'runtime failed',
          ),
        ],
      );
      final restored = SourceWorkspaceSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      expect(restored.files.single.cursor, 7);
      expect(restored.files.single.previousSource, 'original');
      expect(restored.toJson(), snapshot.toJson());
    },
  );
}
