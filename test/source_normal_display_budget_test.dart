import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _requirement =
    'Make the complete requested game using every existing file and control.';
SourceFilePlan _plan(
  String id,
  SourceFileKind kind, [
  List<String> dependencies = const [],
]) => SourceFilePlan(
  id: id,
  kind: kind,
  purpose: 'Keep every requested feature',
  dependsOn: dependencies,
);
SourceWorkspaceSnapshot _draft(String css, String js, String prefix) {
  final style = _plan('styles.css', SourceFileKind.css);
  final logic = _plan('game.js', SourceFileKind.js);
  final page = _plan('index.html', SourceFileKind.html, [
    'styles.css',
    'game.js',
  ]);
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(_requirement),
    experienceType: 'game',
    blueprintComplete: true,
    blueprint: SourceBlueprint(
      title: 'Complete game',
      summary: 'All features retained',
      skillInstructions: 'Start, pause and restart',
      interfaces: 'Preserve all original CSS/JS contracts',
      files: [style, logic, page],
    ),
    files: [
      SourceFileSnapshot(plan: style, source: css, complete: true),
      SourceFileSnapshot(plan: logic, source: js, complete: true),
      SourceFileSnapshot(plan: page, source: prefix),
    ],
  );
}

Map<String, Object?> _display(List<Message> messages) {
  const marker = 'Host-owned source display (immutable data): ';
  final text = messages.first.content;
  return Map<String, Object?>.from(
    jsonDecode(text.substring(text.indexOf(marker) + marker.length)) as Map,
  );
}

String _text(Map data) => (data['ranges'] as List)
    .map((range) => (range as Map)['text'] as String)
    .join();
int _bytes(List<Message> messages) => utf8
    .encode(
      jsonEncode({
        'turnId': '00000000-0000-0000-0000-000000000000',
        'generationMode': 'project_source',
        'streamProtocol': 'maaso_sse_v1',
        'outputFormat': 'json_object',
        'model': 'reserved-provider-model-name' * 32,
        'temperature': 0.2,
        'messages': messages.map((message) => message.toJson()).toList(),
      }),
    )
    .length;
String _padded(int bytes, int markerOffset, String marker) =>
    ' ' * markerOffset +
    marker +
    ' ' * (bytes - markerOffset - utf8.encode(marker).length);

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.verify);
  final void Function(List<Message>) verify;
  final requests = <List<Message>>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    requests.add(messages);
    verify(messages);
    final binding = RegExp(
      r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
    ).firstMatch(messages.first.content)!;
    return ProjectSourceResponse(
      termination: ProjectSourceTermination.complete,
      visibleText: jsonEncode({
        'fileId': binding[1],
        'baseCursor': int.parse(binding[2]!),
        'prefixHash': binding[3],
        'append': '<main>Complete screen</main>',
        'done': true,
      }),
    );
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('no ordinary model call');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('no flattened prompt');
}

Future<dynamic> _generate(_Client client, SourceWorkspaceSnapshot draft) =>
    GeneratedGameArtifact(
      client: client,
      instruction: _requirement,
      surfaceId: 'host-owned',
      zh: false,
      initialDraft: draft,
    ).generate();

void main() {
  test(
    'empty initial HTML shows complete real-size CSS and JS including their formerly hidden middle contracts',
    () async {
      final css = _padded(12041, 3644, '.overlay.hidden{display:none}');
      final js = _padded(20369, 3930, 'const startOverlay="overlay";');
      expect(utf8.encode(css).length + utf8.encode(js).length, 32410);
      final client = _Client((messages) {
        final display = _display(messages);
        expect((display['current'] as Map)['ranges'], isEmpty);
        final dependencies = (display['dependencies'] as List).cast<Map>();
        expect(dependencies, hasLength(2));
        for (final dependency in dependencies) {
          expect(dependency['ranges'], hasLength(1));
          expect(
            _text(dependency),
            dependency['fileId'] == 'styles.css' ? css : js,
          );
        }
        expect(messages.first.content, contains('.overlay.hidden'));
        expect(messages.first.content, contains('startOverlay'));
        expect(_bytes(messages), lessThanOrEqualTo(200 * 1024));
      });
      final artifact = await _generate(client, _draft(css, js, ''));
      expect(client.requests, hasLength(1));
      final surface = artifact.actions.single['surface'] as Map;
      expect(surface['css'], css);
      expect(surface['js'], js);
      expect(surface['html'], '<main>Complete screen</main>');
    },
  );

  test(
    'a fitting UTF8 prefix above the old two-thirds share and all dependencies remain complete',
    () async {
      final prefix = '界' * 8000; // 24000 bytes, above the old 21845-byte share.
      final css = _padded(3000, 1300, '.panel.hidden{}');
      final js = _padded(5000, 2100, 'const expectedControl=true;');
      final client = _Client((messages) {
        final display = _display(messages), current = display['current'] as Map;
        expect(current['fullBytes'], 24000);
        expect(current['ranges'], hasLength(1));
        expect(_text(current), prefix);
        for (final dependency
            in (display['dependencies'] as List).cast<Map>()) {
          expect(dependency['ranges'], hasLength(1));
          expect(
            _text(dependency),
            dependency['fileId'] == 'styles.css' ? css : js,
          );
        }
        expect(messages.first.content, contains('"baseCursor":24000'));
      });
      final artifact = await _generate(client, _draft(css, js, prefix));
      expect(
        (artifact.actions.single['surface'] as Map)['html'],
        '$prefix<main>Complete screen</main>',
      );
    },
  );

  test(
    'overflow reserves only actual prefix bytes and keeps large dependency displays and encoded request bounded',
    () async {
      const prefix = '<main>界';
      final css = '"\u0000\\' * 40000;
      final js = '"\u0000\\' * 40000;
      final client = _Client((messages) {
        final display = _display(messages), current = display['current'] as Map;
        expect(_text(current), prefix);
        final dependencies = (display['dependencies'] as List).cast<Map>();
        final displayedBytes =
            utf8.encode(_text(current)).length +
            dependencies.fold<int>(
              0,
              (sum, dependency) => sum + utf8.encode(_text(dependency)).length,
            );
        expect(displayedBytes, lessThanOrEqualTo(32768));
        expect(_bytes(messages), lessThanOrEqualTo(200 * 1024));
        expect(messages.last.content, _requirement);
        expect(
          dependencies.every(
            (dependency) => (dependency['ranges'] as List).length == 2,
          ),
          isTrue,
        );
      });
      final artifact = await _generate(client, _draft(css, js, prefix));
      final surface = artifact.actions.single['surface'] as Map;
      expect(surface['css'], css);
      expect(surface['js'], js);
      expect(surface['html'], '$prefix<main>Complete screen</main>');
      expect(client.requests, hasLength(1));
    },
  );
}
