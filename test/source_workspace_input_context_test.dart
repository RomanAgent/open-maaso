import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _requirement = '保留全部玩法、页面、规则和已有源码，继续完整制作';
const _html = '<main>完整作品</main>';
SourceFilePlan _plan(
  String id,
  SourceFileKind kind, {
  List<String> dependencies = const [],
}) => SourceFilePlan(
  id: id,
  kind: kind,
  purpose: 'Complete requested module $id',
  dependsOn: dependencies,
);
SourceWorkspaceSnapshot _draft(
  String prefix, {
  String? previous,
  String requirement = _requirement,
  String interfaces =
      'page owns the visible UI; logic implements every requested feature',
  List<SourceFileSnapshot> dependencies = const [],
}) {
  final page = SourceFileSnapshot(
    plan: _plan('page', SourceFileKind.html),
    source: _html,
    complete: true,
  );
  final logic = SourceFileSnapshot(
    plan: _plan(
      'logic',
      SourceFileKind.js,
      dependencies: dependencies.map((file) => file.plan.id).toList(),
    ),
    source: prefix,
    previousSource: previous,
    repairDiagnostic: previous == null
        ? null
        : 'surface worker first frame rejected: runtime_failed',
  );
  final files = [page, ...dependencies, logic];
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(requirement),
    experienceType: 'game',
    blueprint: SourceBlueprint(
      title: 'Complete project',
      summary: 'Host validation remains',
      skillInstructions: 'Every requested feature remains',
      interfaces: interfaces,
      files: files.map((file) => file.plan).toList(),
    ),
    blueprintComplete: true,
    files: files,
  );
}

Map<String, Object?> _read({
  String fileId = 'logic',
  int start = 0,
  int maximum = 4096,
  String? version,
}) => {
  'read': {
    'fileId': fileId,
    'startByte': start,
    'maxBytes': maximum,
    'sourceVersion': ?version,
  },
};
Object _chunk(List<Message> messages, String append) {
  final binding = RegExp(
    r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
  ).firstMatch(messages.first.content)!;
  return {
    'fileId': binding[1],
    'baseCursor': int.parse(binding[2]!),
    'prefixHash': binding[3],
    'append': append,
    'done': true,
  };
}

int _requestBytes(List<Message> messages) => utf8
    .encode(
      jsonEncode({
        'turnId': '00000000-0000-0000-0000-000000000000',
        'generationMode': 'project_source',
        'streamProtocol': 'maaso_sse_v1',
        'model': 'provider-model',
        'temperature': 0.2,
        'outputFormat': 'json_object',
        'messages': messages.map((message) => message.toJson()).toList(),
      }),
    )
    .length;
GeneratedGameArtifact _producer(
  _Client client,
  SourceWorkspaceSnapshot initial, {
  String requirement = _requirement,
  FutureOr<void> Function(SourceWorkspaceSnapshot)? onDraft,
  bool Function()? shouldCancel,
}) => GeneratedGameArtifact(
  client: client,
  instruction: requirement,
  surfaceId: 'host-full-project',
  zh: true,
  initialDraft: initial,
  onDraft: onDraft,
  shouldCancel: shouldCancel,
);

void main() {
  for (final kind in [SourceFileKind.css, SourceFileKind.js]) {
    test(
      '${kind.name} without declared dependencies sees the actual completed HTML contract',
      () async {
        const html =
            '<main class="game-shell"><section class="hud-item">分数</section>'
            '<button id="actualStart" class="actual-primary">开始</button></main>';
        final page = SourceFileSnapshot(
          plan: _plan('page', SourceFileKind.html),
          source: html,
          complete: true,
        );
        final target = SourceFileSnapshot(plan: _plan('target', kind));
        final files = [
          page,
          if (kind == SourceFileKind.css)
            SourceFileSnapshot(
              plan: _plan('engine', SourceFileKind.js),
              source: 'const gameReady=true;',
              complete: true,
            ),
          target,
        ];
        final draft = SourceWorkspaceSnapshot(
          requirementSha256: sourceWorkspaceDigest(_requirement),
          experienceType: 'game',
          blueprint: SourceBlueprint(
            title: 'Actual DOM contract',
            summary: 'Complete requested game',
            skillInstructions: 'Use all actual controls',
            interfaces: 'page owns the visible UI',
            files: files.map((file) => file.plan),
          ),
          blueprintComplete: true,
          files: files,
        );
        final source = kind == SourceFileKind.css
            ? '.actual-primary{min-height:48px}'
            : 'document.getElementById("actualStart");';
        final client = _Client([
          (messages) {
            expect(messages.last.content, _requirement);
            expect(messages.first.content, contains('"dependsOn":[]'));
            expect(messages.first.content, contains('actual IDs, classes'));
            final display =
                jsonDecode(
                      messages.first.content
                          .split('Host-owned source display (immutable data): ')
                          .last,
                    )
                    as Map;
            final pageDisplay = (display['dependencies'] as List)
                .cast<Map>()
                .singleWhere((file) => file['fileId'] == 'page');
            expect(pageDisplay['sha256'], sourceWorkspaceDigest(html));
            expect(
              (pageDisplay['ranges'] as List).cast<Map>().single['text'],
              html,
            );
            return _chunk(messages, source);
          },
        ]);
        final saved = <SourceWorkspaceSnapshot>[];
        final result = await _producer(
          client,
          draft,
          onDraft: saved.add,
        ).generate();
        expect((result.actions.single['surface'] as Map)['html'], html);
        expect((result.actions.single['surface'] as Map)[kind.name], source);
        expect(
          saved.last.files
              .singleWhere((file) => file.plan.id == 'target')
              .plan
              .dependsOn,
          isEmpty,
        );
      },
    );
  }

  test(
    'actual HTML context supplements and preserves explicit source dependencies',
    () async {
      const themeSource = '.retained-theme{min-height:48px}';
      final theme = SourceFileSnapshot(
        plan: _plan('theme', SourceFileKind.css),
        source: themeSource,
        complete: true,
      );
      final client = _Client([
        (messages) {
          final display =
              jsonDecode(
                    messages.first.content
                        .split('Host-owned source display (immutable data): ')
                        .last,
                  )
                  as Map;
          final dependencies = (display['dependencies'] as List).cast<Map>();
          expect(
            dependencies.map((file) => file['fileId']),
            containsAll(['page', 'theme']),
          );
          expect(
            dependencies.singleWhere(
              (file) => file['fileId'] == 'theme',
            )['sha256'],
            sourceWorkspaceDigest(themeSource),
          );
          expect(messages.first.content, contains('"dependsOn":["theme"]'));
          return _chunk(messages, 'true;');
        },
      ]);
      final saved = <SourceWorkspaceSnapshot>[];
      final result = await _producer(
        client,
        _draft('const allFeatures=', dependencies: [theme]),
        onDraft: saved.add,
      ).generate();
      final surface = result.actions.single['surface'] as Map;
      expect(surface['css'], themeSource);
      expect(surface['js'], 'const allFeatures=true;');
      expect(saved.last.files.last.plan.dependsOn, ['theme']);
    },
  );

  test(
    'large implicit HTML context remains fully inspectable without reducing the requirement or source',
    () async {
      const marker =
          '<button id="actualMiddleControl" class="actual-primary">开始</button>';
      final html =
          '<main>${'x' * (280 * 1024)}$marker${'y' * (280 * 1024)}</main>';
      final page = SourceFileSnapshot(
        plan: _plan('page', SourceFileKind.html),
        source: html,
        complete: true,
      );
      final target = SourceFileSnapshot(
        plan: _plan('style', SourceFileKind.css),
      );
      final files = [
        page,
        SourceFileSnapshot(
          plan: _plan('engine', SourceFileKind.js),
          source: 'const gameReady=true;',
          complete: true,
        ),
        target,
      ];
      final draft = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_requirement),
        experienceType: 'game',
        blueprint: SourceBlueprint(
          title: 'Full large HTML',
          summary: 'Every requested screen and control remains',
          skillInstructions: 'Use the actual middle control',
          interfaces: 'page owns all screens; style preserves their controls',
          files: files.map((file) => file.plan),
        ),
        blueprintComplete: true,
        files: files,
      );
      const css = '.actual-primary{min-height:48px}';
      final client = _Client([
        (messages) {
          expect(messages.first.content, isNot(contains(marker)));
          expect(messages.first.content, contains(sourceWorkspaceDigest(html)));
          expect(messages.first.content, contains('"fileId":"page"'));
          expect(messages.first.content, contains('"ownedFileIds"'));
          return _read(
            fileId: 'page',
            start: html.indexOf(marker),
            maximum: 256,
          );
        },
        (messages) {
          expect(messages.first.content, contains('readResult'));
          expect(messages.first.content, contains('actualMiddleControl'));
          return _chunk(messages, css);
        },
      ]);
      final saved = <SourceWorkspaceSnapshot>[];
      final result = await _producer(
        client,
        draft,
        onDraft: saved.add,
      ).generate();
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], html);
      expect(surface['css'], css);
      expect(client.messages, hasLength(2));
      expect(
        client.messages.every(
          (messages) => messages.last.content == _requirement,
        ),
        isTrue,
      );
      expect(
        client.messages.map(_requestBytes),
        everyElement(lessThanOrEqualTo(200 * 1024)),
      );
      expect(
        saved.last.files.singleWhere((file) => file.plan.id == 'page').source,
        html,
      );
      expect(
        saved
            .take(saved.length - 1)
            .map((snapshot) => snapshot.executionDigest)
            .toSet(),
        {draft.executionDigest},
      );
      expect(saved.last.executionDigest, isNot(draft.executionDigest));
      final inspection = saved
          .singleWhere(
            (snapshot) =>
                snapshot.executionCheckpoint?.requestPending == true &&
                snapshot.executionCheckpoint?.phase == 'inspection',
          )
          .executionCheckpoint!;
      final display =
          jsonDecode(
                inspection.systemPrompt
                    .split('Host-owned source display (immutable data): ')
                    .last,
              )
              as Map;
      final readResult = display['readResult'] as Map;
      expect(readResult['text'], startsWith(marker));
      expect(
        utf8.encode(readResult['text'] as String),
        utf8
            .encode(html)
            .sublist(
              readResult['startByte'] as int,
              readResult['endByte'] as int,
            ),
      );
      expect(inspection.state['recentReads'], hasLength(1));
    },
  );

  test(
    'UTF-8 display ranges preserve character boundaries without replacing source',
    () {
      const source = '界🕹菜单abcdef';
      final ranges = SourceTextRange.window(source, 8);
      expect(
        ranges.fold<int>(
          0,
          (sum, range) => sum + utf8.encode(range.text).length,
        ),
        lessThanOrEqualTo(8),
      );
      for (final range in ranges) {
        expect(
          utf8.decode(
            utf8.encode(source).sublist(range.startByte, range.endByte),
          ),
          range.text,
        );
      }
      final result = SourceInspectionRequest.tryDecode(
        jsonEncode(_read(maximum: 4)),
      )!.read(_draft(source));
      expect(result.range.text, '界');
      expect(result.range.endByte, 3);
      expect(source, '界🕹菜单abcdef');
    },
  );

  test(
    'the readonly union rejects foreign files, paths, authority, invalid integers and misaligned UTF-8',
    () {
      final draft = _draft('界🕹abcdef');
      final invalid = <Object>[
        _read(fileId: 'foreign'),
        _read(fileId: '/tmp/secret'),
        _read(start: 1),
        _read(start: 999),
        _read(maximum: 3),
        _read(maximum: 16385),
        _read(version: 'host'),
        _read(version: 'previous'),
        {
          'read': {'fileId': 'logic', 'startByte': 0.0, 'maxBytes': 4},
        },
        {
          'read': {'fileId': 'logic', 'startByte': 0, 'maxBytes': 4.0},
        },
        {
          'read': {
            'fileId': 'logic',
            'startByte': 0,
            'maxBytes': 4,
            'sourceVersion': null,
          },
        },
        {
          'read': {
            'fileId': 'logic',
            'startByte': 0,
            'maxBytes': 4,
            'path': '/tmp/secret',
          },
        },
        {..._read(), 'actions': []},
      ];
      for (final value in invalid) {
        expect(
          () =>
              SourceInspectionRequest.tryDecode(jsonEncode(value))!.read(draft),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
      expect(
        () => SourceInspectionRequest.tryDecode(
          '{"read":{"fileId":"logic","startByte":0,"maxBytes":4}',
        ),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
      for (final raw in [
        '{"read":{"fileId":"logic","startByte":0,"maxBytes":4},"read":{}}',
        '{"read":{"fileId":"logic","fileId":"foreign","startByte":0,"maxBytes":4}}',
      ]) {
        expect(
          () => SourceInspectionRequest.tryDecode(raw),
          throwsA(isA<SourceWorkspaceProtocolException>()),
        );
      }
    },
  );

  test(
    'a source over 512KiB can read an earlier span and append without dropping any bytes',
    () async {
      const marker = 'OLDER_FUNCTION_MUST_BE_INSPECTED';
      final prefix = '${'a' * (280 * 1024)}$marker${'b' * (280 * 1024)}';
      const append = ';const complete=true;';
      final client = _Client([
        (messages) {
          expect(messages.first.content, isNot(contains(marker)));
          expect(messages.first.content, contains('display-only'));
          expect(
            messages.first.content,
            contains(sourceWorkspaceDigest(prefix)),
          );
          return _read(start: 280 * 1024);
        },
        (messages) {
          expect(messages.first.content, contains('readResult'));
          expect(messages.first.content, contains(marker));
          return _chunk(messages, append);
        },
      ]);
      final saved = <SourceWorkspaceSnapshot>[];
      final result = await _producer(
        client,
        _draft(prefix),
        onDraft: saved.add,
      ).generate();
      expect((result.actions.single['surface'] as Map)['js'], prefix + append);
      expect(client.messages, hasLength(2));
      expect(
        client.messages.every(
          (messages) => messages.last.content == _requirement,
        ),
        isTrue,
      );
      expect(
        client.messages.map(_requestBytes),
        everyElement(lessThanOrEqualTo(200 * 1024)),
      );
      expect(saved.last.files.last.source, prefix + append);
      // Reads persist continuation context, but only the accepted append may
      // advance the stored source version.
      final sourceIdentity = _draft(prefix).executionDigest;
      expect(
        saved
            .take(saved.length - 1)
            .map((snapshot) => snapshot.executionDigest)
            .toSet(),
        {sourceIdentity},
      );
      expect(saved.last.executionDigest, isNot(sourceIdentity));
      final inspection = saved
          .singleWhere(
            (snapshot) =>
                snapshot.executionCheckpoint?.requestPending == true &&
                snapshot.executionCheckpoint?.phase == 'inspection',
          )
          .executionCheckpoint!;
      expect(inspection.systemPrompt, contains(marker));
      expect(inspection.state['recentReads'], hasLength(1));
    },
  );

  test(
    'repair can inspect the complete previous version through a bounded readonly range',
    () async {
      const marker = 'PREVIOUS_RULES_TO_KEEP';
      final previous = '${'x' * (280 * 1024)}$marker${'y' * (280 * 1024)}';
      const prefix = 'const replacement=';
      final client = _Client([
        (messages) {
          expect(messages.first.content, isNot(contains(marker)));
          return _read(start: 280 * 1024, version: 'previous');
        },
        (messages) {
          expect(messages.first.content, contains(marker));
          expect(
            messages.first.content,
            contains('"sourceVersion":"previous"'),
          );
          return _chunk(messages, 'true;');
        },
      ]);
      final result = await _producer(
        client,
        _draft(prefix, previous: previous),
      ).generate();
      expect(
        (result.actions.single['surface'] as Map)['js'],
        '$prefix'
        'true;',
      );
      expect(
        client.messages.map(_requestBytes),
        everyElement(lessThanOrEqualTo(200 * 1024)),
      );
    },
  );

  test(
    'A then B then A retains cross-function data and can complete with one bounded repeat stall',
    () async {
      final prefix =
          '${'x' * 30000}FUNCTION_ALPHA${'y' * 30000}FUNCTION_BETA${'z' * 30000}';
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _read(start: 30000, maximum: 64),
        (messages) {
          expect(
            saved.every(
              (snapshot) =>
                  snapshot.executionDigest == _draft(prefix).executionDigest,
            ),
            isTrue,
          );
          expect(
            saved.last.executionCheckpoint!.systemPrompt,
            messages.first.content,
          );
          expect(
            saved.last.executionCheckpoint!.state['recentReads'],
            hasLength(1),
          );
          return _read(start: 60014, maximum: 64);
        },
        (messages) {
          expect(messages.first.content, contains('FUNCTION_ALPHA'));
          expect(messages.first.content, contains('FUNCTION_BETA'));
          expect(
            saved.every(
              (snapshot) =>
                  snapshot.executionDigest == _draft(prefix).executionDigest,
            ),
            isTrue,
          );
          expect(
            saved.last.executionCheckpoint!.systemPrompt,
            messages.first.content,
          );
          expect(
            saved.last.executionCheckpoint!.state['recentReads'],
            hasLength(2),
          );
          return _read(start: 30000, maximum: 64);
        },
        (messages) {
          expect(messages.first.content, contains('FUNCTION_ALPHA'));
          expect(messages.first.content, contains('FUNCTION_BETA'));
          return _chunk(messages, ';const complete=true;');
        },
      ]);
      final result = await _producer(
        client,
        _draft(prefix),
        onDraft: saved.add,
      ).generate();
      expect(client.messages, hasLength(4));
      expect(
        saved.map((snapshot) => snapshot.executionDigest).toSet(),
        hasLength(2),
      );
      expect(
        saved
            .take(saved.length - 1)
            .every((snapshot) => snapshot.files.last.source == prefix),
        isTrue,
      );
      expect(saved.any((snapshot) => snapshot.stallCount == 1), isTrue);
      expect(saved.every((snapshot) => snapshot.stallCount <= 1), isTrue);
      expect(
        (result.actions.single['surface'] as Map)['js'],
        '$prefix;const complete=true;',
      );
    },
  );

  test(
    'an evicted inspection can be checkpointed again without changing or dropping source',
    () async {
      final prefix = List.generate(6, (i) => '${'x' * 30000}BLOCK_$i').join();
      final offsets = List.generate(5, (i) => prefix.indexOf('BLOCK_$i'));
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _read(start: offsets[0], maximum: 64),
        for (var i = 1; i < 5; i++)
          (_) => _read(start: offsets[i], maximum: 64),
        (messages) {
          expect(messages.first.content, isNot(contains('BLOCK_0')));
          return _read(start: offsets[0], maximum: 64);
        },
        (messages) {
          expect(messages.first.content, contains('BLOCK_0'));
          return _chunk(messages, ';const all=true;');
        },
      ]);
      final result = await _producer(
        client,
        _draft(prefix),
        onDraft: saved.add,
      ).generate();
      expect(client.messages, hasLength(7));
      expect(
        saved.map((snapshot) => snapshot.executionDigest).toSet(),
        hasLength(2),
      );
      expect(
        saved
            .take(saved.length - 1)
            .every((snapshot) => snapshot.files.last.source == prefix),
        isTrue,
      );
      final inspections = saved
          .where(
            (snapshot) =>
                snapshot.executionCheckpoint?.requestPending == true &&
                snapshot.executionCheckpoint?.phase == 'inspection',
          )
          .map((snapshot) => snapshot.executionCheckpoint!)
          .toList();
      expect(inspections, isNotEmpty);
      expect(inspections.last.systemPrompt, contains('BLOCK_0'));
      expect(
        inspections.every(
          (checkpoint) => (checkpoint.state['recentReads'] as List).length <= 4,
        ),
        isTrue,
      );
      expect(
        (result.actions.single['surface'] as Map)['js'],
        '$prefix;const all=true;',
      );
      expect(
        client.messages.map(_requestBytes),
        everyElement(lessThanOrEqualTo(200 * 1024)),
      );
    },
  );

  test(
    '50 high-escape dependencies share one adaptive display budget and preserve complete output',
    () async {
      final dependencies = List.generate(
        50,
        (index) => SourceFileSnapshot(
          plan: _plan('module$index', SourceFileKind.js),
          source: '"\u0000\\' * 8000,
          complete: true,
        ),
      );
      final requirement = '$_requirement\n${'"\u0000\\' * 12000}';
      const prefix = 'const allFeatures=';
      final client = _Client([
        (messages) {
          expect(messages.last.content, requirement);
          expect(
            messages.first.content,
            contains('COMPLETE_INTERFACES_ARE_RETAINED'),
          );
          return _chunk(messages, 'true;');
        },
      ]);
      final result = await _producer(
        client,
        _draft(
          prefix,
          requirement: requirement,
          dependencies: dependencies,
          interfaces: 'COMPLETE_INTERFACES_ARE_RETAINED',
        ),
        requirement: requirement,
      ).generate();
      expect(client.messages, hasLength(1));
      expect(
        _requestBytes(client.messages.single),
        lessThanOrEqualTo(200 * 1024),
      );
      expect(
        (result.actions.single['surface'] as Map)['js'],
        [
          ...dependencies.map((file) => file.source),
          '$prefix'
              'true;',
        ].join('\n;\n'),
      );
    },
  );

  test(
    'fixed full requirements or interfaces over the input budget dispatch nothing and retain the draft',
    () async {
      for (final giantRequirement in [false, true]) {
        final requirement = giantRequirement ? '全' * (80 * 1024) : _requirement;
        final draft = _draft(
          'const preserved=',
          requirement: requirement,
          interfaces: giantRequirement ? 'Full interfaces' : '界' * (80 * 1024),
        );
        final client = _Client([]);
        final saved = <SourceWorkspaceSnapshot>[];
        await expectLater(
          _producer(
            client,
            draft,
            requirement: requirement,
            onDraft: saved.add,
          ).generate(),
          throwsA(
            isA<GeneratedTaskFailure>().having(
              (failure) => failure.code,
              'code',
              GeneratedTaskFailureCode.modelContextLimit,
            ),
          ),
        );
        expect(client.messages, isEmpty);
        expect(saved.last.files.last.source, 'const preserved=');
        expect(saved.last.blueprint!.interfaces, draft.blueprint!.interfaces);
      }
    },
  );

  test(
    'plan pagination guards full accepted interfaces before another request and keeps that plan',
    () async {
      final interfaces = '界' * (80 * 1024);
      final initial = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_requirement),
        experienceType: 'game',
      );
      final client = _Client([
        (_) => {
          'title': 'Complete plan',
          'summary': 'Continue all files',
          'skillInstructions': 'Keep the complete feature set',
          'interfaces': interfaces,
          'files': [
            {'id': 'page', 'kind': 'html', 'purpose': 'All screens'},
          ],
          'done': false,
        },
      ]);
      final saved = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, initial, onDraft: saved.add).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.modelContextLimit,
          ),
        ),
      );
      expect(client.messages, hasLength(1));
      expect(saved.last.blueprint!.interfaces, interfaces);
      expect(saved.last.blueprintComplete, isFalse);
    },
  );

  test(
    'a foreign inspection from the provider is rejected without a second dispatch',
    () async {
      final client = _Client([(_) => _read(fileId: 'another-account-file')]);
      await expectLater(
        _producer(client, _draft('const owned=true;')).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.responseInvalid,
          ),
        ),
      );
      expect(client.messages, hasLength(1));
    },
  );

  test(
    'inspection checkpoints retain source and repeated inspected ranges stop after three stalls',
    () async {
      final prefix = 'a' * 10000;
      final client = _Client([
        (_) => _read(start: 0),
        (_) => _read(start: 5000),
        (_) => _read(start: 0),
        (_) => _read(start: 0),
        (_) => _read(start: 0),
      ]);
      final saved = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, _draft(prefix), onDraft: saved.add).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.messages, hasLength(5));
      expect(saved.map((snapshot) => snapshot.executionDigest).toSet(), {
        _draft(prefix).executionDigest,
      });
      expect(saved.map((snapshot) => snapshot.stallCount).toSet(), {
        0,
        1,
        2,
        3,
      });
      expect(saved.last.stallCount, 3);
      expect(
        saved.any(
          (snapshot) =>
              (snapshot.executionCheckpoint?.state['recentReads'] as List?)
                  ?.length ==
              2,
        ),
        isTrue,
      );
      expect(saved.every((draft) => draft.files.last.source == prefix), isTrue);
    },
  );

  test(
    'empty source inspection stalls and cancellation prevents a later read dispatch',
    () async {
      final emptyClient = _Client(
        List.generate(
          3,
          (_) =>
              (_) => _read(),
        ),
      );
      await expectLater(
        _producer(emptyClient, _draft('')).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(emptyClient.messages, hasLength(3));
      var cancelled = false;
      final cancelledClient = _Client([
        (_) {
          cancelled = true;
          return _read();
        },
      ]);
      await expectLater(
        _producer(
          cancelledClient,
          _draft('const preserved=true;'),
          shouldCancel: () => cancelled,
        ).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(cancelledClient.messages, hasLength(1));
    },
  );
}

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.responses);
  final List<Object Function(List<Message>)> responses;
  final messages = <List<Message>>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> request, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    messages.add(List.unmodifiable(request));
    return ProjectSourceResponse(
      visibleText: jsonEncode(responses.removeAt(0)(request)),
      termination: ProjectSourceTermination.complete,
    );
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('not ordinary chat');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('not legacy JSON');
}
