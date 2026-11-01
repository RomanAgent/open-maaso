import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _requirement = '生成完整项目，容量错误不得截断源码或替换内容';
final _capacityFailure = isA<GeneratedTaskFailure>().having(
  (failure) => failure.code.name,
  'code',
  'generationCapacityExceeded',
);

int _themeBytes(String css) {
  final source = <String, Object?>{
    'rendering': 'webApp',
    'transparent': false,
    'css': css,
  };
  SurfaceAuthoringTheme.applyToNewSource(source);
  return utf8.encode(source['css'] as String).length;
}

SourceWorkspaceSnapshot _draft(
  List<(String, SourceFileKind, String, bool)> sources,
) {
  final files = sources
      .map(
        (entry) => SourceFileSnapshot(
          plan: SourceFilePlan(
            id: entry.$1,
            kind: entry.$2,
            purpose: 'Preserve this complete module',
            dependsOn: const [],
          ),
          source: entry.$3,
          complete: entry.$4,
        ),
      )
      .toList();
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(_requirement),
    experienceType: 'game',
    blueprint: SourceBlueprint(
      title: 'Full source',
      summary: 'Awaiting host verification',
      skillInstructions: 'All requested functions remain',
      files: files.map((file) => file.plan).toList(),
    ),
    blueprintComplete: true,
    files: files,
  );
}

GeneratedGameArtifact _producer(
  _CapacityClient client,
  SourceWorkspaceSnapshot initial, {
  FutureOr<void> Function(SourceWorkspaceSnapshot)? onDraft,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'host-capacity-id',
  zh: true,
  initialDraft: initial,
  onDraft: onDraft,
);

void main() {
  test(
    'an oversized append stops before persistence and retains the last legal draft',
    () async {
      const html = '<main>完整游戏</main>';
      final remaining =
          SurfaceProjectValidator.maximumPublicSourceBytes -
          utf8.encode(html).length -
          _themeBytes('');
      final prefix = 'a' * remaining;
      final initial = _draft([
        ('page', SourceFileKind.html, html, true),
        ('logic', SourceFileKind.js, prefix, false),
      ]);
      final client = _CapacityClient(
        (_) => jsonEncode({
          'fileId': 'logic',
          'baseCursor': utf8.encode(prefix).length,
          'prefixHash': sourceWorkspaceDigest(prefix),
          'append': '🕹',
          'done': false,
        }),
      );
      final saved = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, initial, onDraft: saved.add).generate(),
        throwsA(_capacityFailure),
      );
      expect(client.calls, 1);
      expect(saved, isNotEmpty);
      expect(
        saved.every((snapshot) => snapshot.files.last.source == prefix),
        isTrue,
      );
      expect(saved.last.files.last.cursor, remaining);
    },
  );

  test(
    'restored over-capacity source sends no request and does not overwrite its draft',
    () async {
      final initial = _draft([
        ('page', SourceFileKind.html, '<main>完整游戏</main>', true),
        (
          'logic',
          SourceFileKind.js,
          'a' * SurfaceProjectValidator.maximumPublicSourceBytes,
          false,
        ),
      ]);
      final client = _CapacityClient((_) => throw StateError('must not call'));
      final saved = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, initial, onDraft: saved.add).generate(),
        throwsA(_capacityFailure),
      );
      expect(client.calls, 0);
      expect(saved, isEmpty);
    },
  );

  test(
    'the inclusive UTF-8 boundary includes every module separator and host theme bytes',
    () async {
      const firstHtml = '<main>界🕹</main>';
      const secondHtml = '<aside>菜单</aside>';
      const firstCss = '/*中文样式*/';
      const secondCss = 'button{min-height:48px}';
      const secondJs = 'const finished=true;';
      // HTML/CSS join is one byte, JS join is three bytes; count actual host CSS.
      final remaining =
          SurfaceProjectValidator.maximumPublicSourceBytes -
          utf8.encode(firstHtml).length -
          utf8.encode(secondHtml).length -
          utf8.encode(secondJs).length -
          1 -
          3 -
          _themeBytes('$firstCss\n$secondCss');
      SourceWorkspaceSnapshot boundary(int extra) => _draft([
        ('page', SourceFileKind.html, firstHtml, true),
        ('menu', SourceFileKind.html, secondHtml, true),
        ('style', SourceFileKind.css, firstCss, true),
        ('controls', SourceFileKind.css, secondCss, true),
        ('logic', SourceFileKind.js, 'a' * (remaining + extra), true),
        ('ending', SourceFileKind.js, secondJs, true),
      ]);
      final client = _CapacityClient((_) => throw StateError('must not call'));
      final result = await _producer(client, boundary(0)).generate();
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], '$firstHtml\n$secondHtml');
      expect(surface['css'], '$firstCss\n$secondCss');
      expect(surface['js'], '${'a' * remaining}\n;\n$secondJs');
      final total =
          utf8.encode(surface['html'] as String).length +
          _themeBytes(surface['css'] as String) +
          utf8.encode(surface['js'] as String).length;
      expect(total, SurfaceProjectValidator.maximumPublicSourceBytes);
      await expectLater(
        _producer(client, boundary(1)).generate(),
        throwsA(_capacityFailure),
      );
      expect(client.calls, 0);
    },
  );

  test(
    'a completed theme snapshot is counted once at the source boundary',
    () async {
      const html = '<main>游戏</main>';
      final css = SurfaceAuthoringTheme.cssSnapshot();
      final remaining =
          SurfaceProjectValidator.maximumPublicSourceBytes -
          utf8.encode(html).length -
          utf8.encode(css).length;
      final client = _CapacityClient((_) => throw StateError('must not call'));
      final result = await _producer(
        client,
        _draft([
          ('page', SourceFileKind.html, html, true),
          ('style', SourceFileKind.css, css, true),
          ('logic', SourceFileKind.js, 'a' * remaining, true),
        ]),
      ).generate();
      expect((result.actions.single['surface'] as Map)['css'], css);
      expect(client.calls, 0);
    },
  );
}

class _CapacityClient extends LLMClient implements ProjectSourceLLMClient {
  _CapacityClient(this.reply);
  final String Function(List<Message>) reply;
  int calls = 0;
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    calls++;
    return ProjectSourceResponse(
      visibleText: reply(messages),
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
