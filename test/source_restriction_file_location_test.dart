import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _request = '保留任意玩法、所有关卡和控件，只修宿主实际检查出的错误';
ProjectSourceResponse _response(Object value) => ProjectSourceResponse(
  visibleText: jsonEncode(value),
  termination: ProjectSourceTermination.complete,
);
ProjectSourceResponse _patch(
  String id,
  String source,
  String oldText,
  String newText,
) => _response({
  'fileId': id,
  'baseHash': sourceWorkspaceDigest(source),
  'edits': [
    {'oldText': oldText, 'newText': newText},
  ],
});
ProjectSourceResponse _unchanged(String id, String source) => _response({
  'fileId': id,
  'baseHash': sourceWorkspaceDigest(source),
  'edits': [],
});

GeneratedGameArtifact _producer(
  _Model model,
  Map<String, String> sources,
  List<SourceWorkspaceSnapshot> drafts, {
  String html = '<main id="play">Complete original game</main>',
}) {
  final plans = [
    SourceFilePlan(
      id: 'page',
      kind: SourceFileKind.html,
      purpose: 'Playable markup',
    ),
    for (final id in sources.keys)
      SourceFilePlan(
        id: id,
        kind: SourceFileKind.js,
        purpose: 'Complete original game module',
        dependsOn: ['page'],
      ),
  ];
  return GeneratedGameArtifact(
    client: model,
    instruction: _request,
    surfaceId: 'host-owned',
    zh: true,
    onDraft: drafts.add,
    initialDraft: SourceWorkspaceSnapshot(
      requirementSha256: sourceWorkspaceDigest(_request),
      experienceType: 'game',
      blueprint: SourceBlueprint(
        title: 'Original',
        summary: 'Original full request',
        skillInstructions: 'Original controls',
        interfaces: 'Original interfaces',
        files: plans,
      ),
      blueprintComplete: true,
      files: [
        for (final plan in plans.reversed)
          SourceFileSnapshot(
            plan: plan,
            source: plan.kind == SourceFileKind.html ? html : sources[plan.id]!,
            complete: true,
          ),
      ],
    ),
  );
}

SurfaceProject _project(AgentActionEnvelope envelope) =>
    SurfaceProject.fromJson(envelope.actions.single['surface'] as Map);
const _runtimeFailure = 'surface worker first frame rejected: runtime_failed';
SurfaceRuntimeDiagnostic _atOffset(
  AgentActionEnvelope envelope,
  int offset, {
  String category = 'reference_error',
}) {
  final source = _project(envelope).js;
  final prefix = source.substring(0, offset);
  return SurfaceRuntimeDiagnostic(
    category: category,
    sourceHash: SurfaceRuntimeDiagnostic.hashSource(source),
    line: '\n'.allMatches(prefix).length + 1,
    column: offset - prefix.lastIndexOf('\n'),
  );
}

SurfaceRuntimeDiagnostic _atToken(
  AgentActionEnvelope envelope,
  String token, {
  String category = 'reference_error',
}) => _atOffset(
  envelope,
  _project(envelope).js.indexOf(token),
  category: category,
);
Map<String, Object?> _location(List<Message> request) =>
    Map<String, Object?>.from(
      jsonDecode(
            RegExp(
              r'^Host source location: (\{.*\})$',
              multiLine: true,
            ).firstMatch(request.first.content)!.group(1)!,
          )
          as Map,
    );
String _requestedId(List<Message> request) => RegExp(
  r'File binding: \{"fileId":"([^"]+)"',
).firstMatch(request.first.content)!.group(1)!;

void main() {
  for (final category in ['reference_error', 'type_error']) {
    test(
      'authenticated $category starts at the observed module and preserves healthy source',
      () async {
        const healthy = 'const stableState=1;';
        const faulty = 'const localState=2;\nmissingLocal();';
        final drafts = <SourceWorkspaceSnapshot>[];
        final model = _Model([
          (request) {
            expect(_requestedId(request), 'entry.js');
            expect(request.first.content, contains('"category":"$category"'));
            expect(
              request.first.content,
              contains('"fileId":"entry.js","line":2,"column":1'),
            );
            return _patch(
              'entry.js',
              faulty,
              'missingLocal();',
              'const ready=true;',
            );
          },
          (request) {
            expect(_requestedId(request), 'healthy.js');
            return _unchanged('healthy.js', healthy);
          },
        ]);
        final producer = _producer(model, {
          'healthy.js': healthy,
          'entry.js': faulty,
        }, drafts);
        final original = await producer.generate();
        final source =
            (original.actions.single['surface'] as Map)['js'] as String;
        final prefix = source.substring(0, source.indexOf('missingLocal();'));
        final diagnostic = SurfaceRuntimeDiagnostic(
          category: category,
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(source),
          line: '\n'.allMatches(prefix).length + 1,
          column: 1,
        );
        final repaired = await producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
          runtimeDiagnostic: diagnostic,
        );
        expect(model.requests, hasLength(2));
        expect(_project(repaired).js, contains(healthy));
        expect(
          drafts.last.files
              .singleWhere((file) => file.plan.id == 'healthy.js')
              .source,
          healthy,
        );
        expect(_project(repaired).js, isNot(contains('missingLocal();')));
      },
    );
  }
  test(
    'observed caller TypeError still permits repairing its owned callee',
    () async {
      const healthy = 'const stableLayout=1;';
      const callee = 'function makeContext(){return null;}';
      const caller = 'const context=makeContext();\ncontext.start();';
      final drafts = <SourceWorkspaceSnapshot>[];
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'entry.js');
          expect(
            request.first.content,
            contains('not proof that its root cause is in that module'),
          );
          return _unchanged('entry.js', caller);
        },
        (request) {
          expect(_requestedId(request), 'healthy.js');
          return _unchanged('healthy.js', healthy);
        },
        (request) {
          expect(_requestedId(request), 'callee.js');
          expect(
            request.first.content,
            contains('This request repairs callee.js'),
          );
          return _patch(
            'callee.js',
            callee,
            'return null;',
            'return {start:()=>1};',
          );
        },
      ]);
      final producer = _producer(model, {
        'healthy.js': healthy,
        'callee.js': callee,
        'entry.js': caller,
      }, drafts);
      final original = await producer.generate();
      final source =
          (original.actions.single['surface'] as Map)['js'] as String;
      final prefix = source.substring(0, source.indexOf('context.start();'));
      final result = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
        runtimeDiagnostic: SurfaceRuntimeDiagnostic(
          category: 'type_error',
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(source),
          line: '\n'.allMatches(prefix).length + 1,
          column: 1,
        ),
      );
      expect(model.requests, hasLength(3));
      expect(_project(result).js, contains('return {start:()=>1};'));
      expect(_project(result).js, contains(caller));
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'healthy.js')
            .source,
        healthy,
      );
    },
  );
  test(
    'stale runtime source hash falls back instead of claiming a module location',
    () async {
      const healthy = 'const stable=1;';
      const faulty = 'missing();';
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'healthy.js');
          return _unchanged('healthy.js', healthy);
        },
        (request) {
          expect(_requestedId(request), 'entry.js');
          return _patch('entry.js', faulty, faulty, 'const ready=1;');
        },
      ]);
      final producer = _producer(model, {
        'healthy.js': healthy,
        'entry.js': faulty,
      }, []);
      final original = await producer.generate();
      await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
        runtimeDiagnostic: SurfaceRuntimeDiagnostic(
          category: 'reference_error',
          sourceHash: '0' * 64,
          line: 1,
          column: 1,
        ),
      );
      expect(model.requests, hasLength(2));
      expect(
        model.requests.every(
          (request) => !request.first.content.contains(
            'Authenticated host engine diagnostic:',
          ),
        ),
        isTrue,
      );
    },
  );
  test(
    'successive engine failures are remapped to their current owned modules',
    () async {
      const healthy = 'const healthy=1;';
      const entity = 'function collision(){return missingOwner;}collision();';
      const later = 'const later=2;missingEffect();';
      const fixedEntity = 'function collision(){return {x:0};}collision();';
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'entities.js');
          final location = _location(request);
          expect(location['fileId'], 'entities.js');
          expect(location['localUtf16Offset'], entity.indexOf('missingOwner'));
          expect(
            location['assembledUtf16Offset'],
            healthy.length + 3 + entity.indexOf('missingOwner'),
          );
          expect(location['diagnosticKind'], 'engine');
          return _patch(
            'entities.js',
            entity,
            'return missingOwner;',
            'return {x:0};',
          );
        },
        (_) => _unchanged('healthy.js', healthy),
        (_) => _unchanged('effects.js', later),
        (request) {
          expect(_requestedId(request), 'effects.js');
          expect(
            _location(request)['localUtf16Offset'],
            later.indexOf('missingEffect'),
          );
          return _patch('effects.js', later, 'missingEffect();', '');
        },
        (_) => _unchanged('healthy.js', healthy),
        (_) => _unchanged('entities.js', fixedEntity),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(model, {
        'healthy.js': healthy,
        'entities.js': entity,
        'effects.js': later,
      }, drafts);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atToken(original, 'missingOwner'),
      );
      expect(model.requests, hasLength(3));
      final result = await producer.repair(
        repaired,
        _runtimeFailure,
        runtimeDiagnostic: _atToken(repaired, 'missingEffect'),
      );
      expect(model.requests, hasLength(6));
      expect(
        _project(result).js,
        '$healthy\n;\n$fixedEntity\n;\nconst later=2;',
      );
      expect(
        drafts.every(
          (draft) =>
              draft.files
                  .singleWhere((f) => f.plan.id == 'healthy.js')
                  .source ==
              healthy,
        ),
        isTrue,
      );
      final before = original.actions.single['surface'] as Map,
          after = result.actions.single['surface'] as Map;
      for (final key in [
        'id',
        'title',
        'html',
        'css',
        'manifest',
        'skillInstructions',
        'experienceType',
      ]) {
        expect(after[key], before[key], reason: key);
      }
      expect(
        model.requests.every((request) => request.last.content == _request),
        isTrue,
      );
    },
  );

  test(
    'engine emoji and CRLF locations retain UTF16 offsets and original columns',
    () async {
      const first = 'const decoration="🚀";';
      const target =
          'function pass(){\r\n  const label="☀️🚀"; return missingOwner;\r\n}pass();';
      final model = _Model([
        (request) {
          final location = _location(request),
              local = target.indexOf('missingOwner');
          expect(location['fileId'], 'unicode.js');
          expect(location['assembledUtf16Offset'], first.length + 3 + local);
          expect(location['localUtf16Offset'], local);
          expect(location['line'], 2);
          expect(
            location['column'],
            local - target.substring(0, local).lastIndexOf('\n'),
          );
          expect(
            location['localUtf16Offset'],
            isNot(utf8.encode(target.substring(0, local)).length),
          );
          return _patch(
            'unicode.js',
            target,
            'return missingOwner;',
            'return {label};',
          );
        },
        (_) => _unchanged('first.js', first),
      ]);
      final producer = _producer(model, {
        'first.js': first,
        'unicode.js': target,
      }, []);
      final original = await producer.generate();
      await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atToken(original, 'missingOwner'),
      );
      expect(model.requests, hasLength(2));
    },
  );

  for (final boundary in [0, 1, 2]) {
    test(
      'engine location in separator $boundary keeps broad repair eligibility',
      () async {
        const first = 'const first=1;', second = 'const second=2;';
        final model = _Model([
          (request) {
            expect(_requestedId(request), 'first.js');
            expect(
              request.first.content,
              isNot(contains('Host source location:')),
            );
            return _unchanged('first.js', first);
          },
          (_) => _patch('second.js', second, '2', '3'),
        ]);
        final producer = _producer(model, {
          'first.js': first,
          'second.js': second,
        }, []);
        final original = await producer.generate();
        await producer.repair(
          original,
          _runtimeFailure,
          runtimeDiagnostic: _atOffset(
            original,
            first.length + boundary,
            category: 'syntax_error',
          ),
        );
        expect(model.requests, hasLength(2));
      },
    );
  }

  test(
    'a stale candidate never uses a current-workspace engine location',
    () async {
      const first = 'const first=1;',
          second = 'function pass(){return missingOwner;}pass();';
      final model = _Model([
        (request) {
          expect(
            request.first.content,
            isNot(contains('Host source location:')),
          );
          return _unchanged('first.js', first);
        },
        (_) => _patch(
          'second.js',
          second,
          'return missingOwner;',
          'return {value:1};',
        ),
      ]);
      final producer = _producer(model, {
        'first.js': first,
        'second.js': second,
      }, []);
      final original = await producer.generate();
      final stale = AgentActionEnvelope.parse(
        jsonEncode({
          'reply': original.reply,
          'actions': [
            {
              ...original.actions.single.data,
              'surface': {
                ...original.actions.single['surface'] as Map,
                'js': '// stale\n${_project(original).js}',
              },
            },
          ],
        }),
      );
      await producer.repair(
        stale,
        _runtimeFailure,
        runtimeDiagnostic: _atToken(original, 'missingOwner'),
      );
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'an authenticated SyntaxError repairs its observed module and preserves valid escapes',
    () async {
      const first = 'const first=1;';
      const bad =
          'function draw(){const icon="🚀";}\n\\"use strict\\";\nconst label="say \\"hello\\"";';
      final fixed = bad.replaceFirst('\\"use strict\\";', '"use strict";');
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'renderer.js');
          final location = _location(request);
          expect(location['diagnosticKind'], 'engine');
          expect(location['localUtf16Offset'], bad.indexOf('\\"use'));
          expect(location['line'], 2);
          expect(location['column'], 1);
          expect(request.first.content, contains('never globally unescape'));
          expect(
            request.first.content,
            contains('exactly once as JSON strings'),
          );
          return _patch(
            'renderer.js',
            bad,
            '\\"use strict\\";',
            '"use strict";',
          );
        },
        (_) => _unchanged('first.js', first),
      ]);
      final producer = _producer(model, {
        'first.js': first,
        'renderer.js': bad,
      }, []);
      final original = await producer.generate();
      final result = await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atOffset(
          original,
          first.length + 3 + bad.indexOf('\\"use'),
          category: 'syntax_error',
        ),
      );
      expect(model.requests, hasLength(2));
      expect(_project(original).js, '$first\n;\n$bad');
      expect(_project(result).js, '$first\n;\n$fixed');
    },
  );

  test(
    'engine EOF is an uncertain boundary and does not invent one owning module',
    () async {
      const first = 'const first=1;', second = 'const second=2;';
      final model = _Model([
        (request) {
          expect(
            request.first.content,
            isNot(contains('Host source location:')),
          );
          return _unchanged('first.js', first);
        },
        (_) => _patch('second.js', second, '2', '3'),
      ]);
      final producer = _producer(model, {
        'first.js': first,
        'second.js': second,
      }, []);
      final original = await producer.generate();
      await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atOffset(
          original,
          _project(original).js.length,
          category: 'syntax_error',
        ),
      );
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'unlocated startup failures retain all JS and do not fabricate token context',
    () async {
      const first = 'const first=1;', second = 'const second=2;';
      final model = _Model([
        (request) {
          expect(
            request.first.content,
            isNot(contains('Untrusted owned fault context')),
          );
          return _unchanged('first.js', first);
        },
        (_) => _patch('second.js', second, '2', '3'),
      ]);
      final producer = _producer(model, {
        'first.js': first,
        'second.js': second,
      }, []);
      await producer.repair(await producer.generate(), _runtimeFailure);
      expect(model.requests, hasLength(2));
    },
  );

  for (final coarseEof in [false, true]) {
    test(
      'missing UI parenthesis retains healthy modules with ${coarseEof ? 'uncertain EOF' : 'observed engine token'}',
      () async {
        const data = 'const data=1;',
            entities = 'const entities=2;',
            engine = 'const engine=3;';
        const bad =
            'function draw(g){g.addColorStop(.72,"rgba(255,255,255,.04)";}';
        const old = 'g.addColorStop(.72,"rgba(255,255,255,.04)";';
        const fixed = 'g.addColorStop(.72,"rgba(255,255,255,.04)");';
        final healthy = {
          'data.js': data,
          'entities.js': entities,
          'engine.js': engine,
        };
        ProjectSourceResponse respond(List<Message> request) {
          final id = _requestedId(request);
          if (id == 'ui.js') return _patch(id, bad, old, fixed);
          return _unchanged(id, healthy[id]!);
        }

        final model = _Model(List.filled(4, respond, growable: true));
        final drafts = <SourceWorkspaceSnapshot>[];
        final producer = _producer(model, {...healthy, 'ui.js': bad}, drafts);
        final original = await producer.generate();
        final offset = coarseEof
            ? _project(original).js.length
            : _project(original).js.indexOf('";}') + 1;
        final result = await producer.repair(
          original,
          _runtimeFailure,
          runtimeDiagnostic: _atOffset(
            original,
            offset,
            category: 'syntax_error',
          ),
        );
        expect(model.requests, hasLength(4));
        expect(
          _requestedId(model.requests.first),
          coarseEof ? 'data.js' : 'ui.js',
        );
        expect(
          _project(result).js,
          _project(original).js.replaceFirst(old, fixed),
        );
        for (final entry in healthy.entries) {
          expect(
            drafts.every(
              (d) =>
                  d.files.singleWhere((f) => f.plan.id == entry.key).source ==
                  entry.value,
            ),
            isTrue,
          );
        }
      },
    );
  }

  test(
    'uncertain engine EOF retains repair eligibility for two broken modules',
    () async {
      const healthy = 'const healthy=1;',
          one = 'const one=[1);',
          two = 'const two=[2);';
      final model = _Model([
        (_) => _unchanged('healthy.js', healthy),
        (_) => _patch('one.js', one, '[1)', '[1]'),
        (_) => _patch('two.js', two, '[2)', '[2]'),
      ]);
      final producer = _producer(model, {
        'healthy.js': healthy,
        'one.js': one,
        'two.js': two,
      }, []);
      final original = await producer.generate();
      final result = await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atOffset(
          original,
          _project(original).js.length,
          category: 'syntax_error',
        ),
      );
      expect(model.requests, hasLength(3));
      expect(_project(result).js, contains('const one=[1];'));
      expect(_project(result).js, contains('const two=[2];'));
    },
  );

  for (final futureKind in SourceFileKind.values) {
    test(
      'runtime recovery preserves partial delivery and missing ${futureKind.name} plan files',
      () async {
        const healthy = 'const original=1;',
            partial = 'const replacement=',
            bad = 'const ui=[1);';
        final page = SourceFilePlan(
          id: 'page',
          kind: SourceFileKind.html,
          purpose: 'screen',
        );
        final entity = SourceFilePlan(
          id: 'entities.js',
          kind: SourceFileKind.js,
          purpose: 'entities',
        );
        final ui = SourceFilePlan(
          id: 'ui.js',
          kind: SourceFileKind.js,
          purpose: 'UI',
        );
        final future = SourceFilePlan(
          id: 'future',
          kind: futureKind,
          purpose: 'not yet generated',
        );
        final nextSource = switch (futureKind) {
          SourceFileKind.html =>
            '<section id="future">Additional screen</section>',
          SourceFileKind.css => '#future{color:#fff}',
          SourceFileKind.js => 'const futureReady=true;',
        };
        final initial = SourceWorkspaceSnapshot.fromJson(
          SourceWorkspaceSnapshot(
            requirementSha256: sourceWorkspaceDigest(_request),
            experienceType: 'game',
            blueprintComplete: true,
            blueprint: SourceBlueprint(
              title: 'Game',
              summary: 'Original game',
              skillInstructions: 'Original controls',
              files: [page, entity, ui, future],
            ),
            activeFileId: entity.id,
            files: [
              SourceFileSnapshot(
                plan: page,
                source: '<main>Original game</main>',
                complete: true,
              ),
              SourceFileSnapshot(
                plan: entity,
                source: partial,
                previousSource: healthy,
                repairDiagnostic: _runtimeFailure,
              ),
              SourceFileSnapshot(plan: ui, source: bad, complete: true),
            ],
          ).toJson(),
        );
        final model = _Model([
          (_) => _response({
            'fileId': entity.id,
            'baseCursor': utf8.encode(partial).length,
            'prefixHash': sourceWorkspaceDigest(partial),
            'append': 'true;',
            'done': true,
          }),
          (_) => _response({
            'fileId': future.id,
            'baseCursor': 0,
            'prefixHash': sourceWorkspaceDigest(''),
            'append': nextSource,
            'done': true,
          }),
          (request) {
            expect(_requestedId(request), 'ui.js');
            return _patch(ui.id, bad, '[1)', '[1]');
          },
          (_) => _unchanged(entity.id, '${partial}true;'),
          if (futureKind == SourceFileKind.js)
            (_) => _unchanged(future.id, nextSource),
        ]);
        final drafts = <SourceWorkspaceSnapshot>[];
        final producer = GeneratedGameArtifact(
          client: model,
          instruction: _request,
          surfaceId: 'host-owned',
          zh: true,
          initialDraft: initial,
          onDraft: drafts.add,
        );
        final original = await producer.generate();
        expect(model.requests, hasLength(2));
        expect(
          drafts.last.files.singleWhere((f) => f.plan.id == entity.id).source,
          '${partial}true;',
        );
        expect(
          drafts.last.files.singleWhere((f) => f.plan.id == future.id).source,
          nextSource,
        );
        final result = await producer.repair(
          original,
          _runtimeFailure,
          runtimeDiagnostic: _atToken(
            original,
            '[1)',
            category: 'syntax_error',
          ),
        );
        expect(
          model.requests,
          hasLength(futureKind == SourceFileKind.js ? 5 : 4),
        );
        expect(_project(result).js, contains('const ui=[1];'));
        expect(initial.files.any((f) => f.plan.id == future.id), isFalse);
        expect(
          initial.files.singleWhere((f) => f.plan.id == entity.id).source,
          partial,
        );
        expect(
          initial.files
              .singleWhere((f) => f.plan.id == entity.id)
              .previousSource,
          healthy,
        );
      },
    );
  }

  for (final legacy in [false, true]) {
    test(
      '${legacy ? 'legacy lexer history' : 'runtime history'} resumes the owned replacement without a speculative rollback',
      () async {
        const healthy = 'const entities=1;',
            partial = 'const replacement=',
            bad = 'const ui=[1);';
        final page = SourceFilePlan(
          id: 'page',
          kind: SourceFileKind.html,
          purpose: 'screen',
        );
        final entity = SourceFilePlan(
          id: 'entities.js',
          kind: SourceFileKind.js,
          purpose: 'entities',
        );
        final ui = SourceFilePlan(
          id: 'ui.js',
          kind: SourceFileKind.js,
          purpose: 'UI',
        );
        final initial = SourceWorkspaceSnapshot(
          requirementSha256: sourceWorkspaceDigest(_request),
          experienceType: 'game',
          blueprintComplete: true,
          blueprint: SourceBlueprint(
            title: 'Original',
            summary: 'Original request',
            skillInstructions: 'Original controls',
            files: [page, entity, ui],
          ),
          activeFileId: entity.id,
          files: [
            SourceFileSnapshot(
              plan: page,
              source: '<main>Original game</main>',
              complete: true,
            ),
            SourceFileSnapshot(
              plan: entity,
              source: partial,
              previousSource: healthy,
              repairDiagnostic: legacy
                  ? '${SurfaceProjectValidator.javaScriptLexicalFailurePrefix} (UTF-16 offset 999)'
                  : _runtimeFailure,
            ),
            SourceFileSnapshot(plan: ui, source: bad, complete: true),
          ],
        );
        final model = _Model([
          (_) => _response({
            'fileId': entity.id,
            'baseCursor': utf8.encode(partial).length,
            'prefixHash': sourceWorkspaceDigest(partial),
            'append': 'true;',
            'done': true,
          }),
          (_) => _patch(ui.id, bad, '[1)', '[1]'),
          (_) => _unchanged(entity.id, '${partial}true;'),
        ]);
        final drafts = <SourceWorkspaceSnapshot>[];
        final producer = GeneratedGameArtifact(
          client: model,
          instruction: _request,
          surfaceId: 'host-owned',
          zh: true,
          initialDraft: initial,
          onDraft: drafts.add,
        );
        final original = await producer.generate();
        expect(model.requests, hasLength(1));
        expect(
          drafts.last.files.singleWhere((f) => f.plan.id == entity.id).source,
          '${partial}true;',
        );
        await producer.repair(
          original,
          _runtimeFailure,
          runtimeDiagnostic: _atToken(
            original,
            '[1)',
            category: 'syntax_error',
          ),
        );
        expect(model.requests, hasLength(3));
        expect(
          drafts.last.files
              .singleWhere((f) => f.plan.id == entity.id)
              .previousSource,
          healthy,
        );
        expect(initial.files[1].source, partial);
      },
    );
  }

  test(
    'historical lexical/restriction DTO facts remain parseable without banning browser code',
    () async {
      const fact =
          '${SurfaceProjectValidator.javaScriptRestrictionPrefix} (rule reservedIdentifier, name window, UTF-16 offset 17)';
      expect(
        SurfaceProjectValidator.javaScriptRestrictionFact(fact)?.utf16Offset,
        17,
      );
      expect(
        SurfaceProjectValidator.javaScriptLexicalFailureOffset(
          '${SurfaceProjectValidator.javaScriptLexicalFailurePrefix} (UTF-16 offset 29)',
        ),
        29,
      );
      const source =
          'const owner=window;const saved=localStorage;fetch("https://example.com/data");';
      final producer = _producer(_Model([]), {'entry.js': source}, []);
      final result = await producer.generate();
      expect(_project(result).js, source);
      expect(
        SurfaceProjectValidator.diagnoseForPublicGame(_project(result)),
        isEmpty,
      );
    },
  );

  test(
    'aggregate runtime locations use only JS remaining after data-script mounts',
    () async {
      const mounted = 'const mountedReady=true;',
          remaining = 'missingRemaining();';
      const page =
          '<main>Game</main><script src="https://example.com/library.js"></script><script src="mounted.js"></script>';
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'remaining.js');
          expect(_location(request)['assembledUtf16Offset'], 0);
          return _patch(
            'remaining.js',
            remaining,
            'missingRemaining();',
            'const remainingReady=true;',
          );
        },
        (_) => _unchanged('mounted.js', mounted),
      ]);
      final producer = _producer(
        model,
        {'mounted.js': mounted, 'remaining.js': remaining},
        [],
        html: page,
      );
      final original = await producer.generate();
      expect(_project(original).js, remaining);
      await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: _atToken(original, 'missingRemaining'),
      );
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'owned data-script diagnostics map by unique current source hash without an aggregate offset',
    () async {
      const mounted = 'const note="🚀";\nmissingMounted();',
          remaining = 'const remainingReady=1;';
      const page =
          '<main>Game</main><script src="https://example.com/library.js"></script><script src="mounted.js"></script>';
      final model = _Model([
        (request) {
          expect(_requestedId(request), 'mounted.js');
          final location = _location(request);
          expect(location['assembledUtf16Offset'], isNull);
          expect(
            location['localUtf16Offset'],
            mounted.indexOf('missingMounted'),
          );
          expect(location['line'], 2);
          expect(location['column'], 1);
          return _patch(
            'mounted.js',
            mounted,
            'missingMounted();',
            'const mountedReady=true;',
          );
        },
        (_) => _unchanged('remaining.js', remaining),
      ]);
      final producer = _producer(
        model,
        {'mounted.js': mounted, 'remaining.js': remaining},
        [],
        html: page,
      );
      final original = await producer.generate();
      await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: SurfaceRuntimeDiagnostic(
          category: 'reference_error',
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(mounted),
          line: 2,
          column: 1,
        ),
      );
      expect(model.requests, hasLength(2));
    },
  );

  test(
    'ambiguous duplicate owned-script hashes do not guess a file identity',
    () async {
      const shared = 'missingShared();';
      const page =
          '<main>Game</main><script src="https://example.com/library.js"></script><script src="one.js"></script><script src="two.js"></script>';
      final model = _Model([
        (request) {
          expect(
            request.first.content,
            isNot(contains('Host source location:')),
          );
          return _patch('one.js', shared, shared, 'const oneReady=true;');
        },
        (_) => _unchanged('two.js', shared),
      ]);
      final producer = _producer(
        model,
        {'one.js': shared, 'two.js': shared},
        [],
        html: page,
      );
      final original = await producer.generate();
      await producer.repair(
        original,
        _runtimeFailure,
        runtimeDiagnostic: SurfaceRuntimeDiagnostic(
          category: 'reference_error',
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(shared),
          line: 1,
          column: 1,
        ),
      );
      expect(model.requests, hasLength(2));
    },
  );
}

class _Model extends LLMClient implements ProjectSourceLLMClient {
  _Model(this.responses);
  final List<ProjectSourceResponse Function(List<Message>)> responses;
  final requests = <List<Message>>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    requests.add(List.unmodifiable(messages));
    return responses.removeAt(0)(messages);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('not ordinary chat');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('not legacy JSON');
}
