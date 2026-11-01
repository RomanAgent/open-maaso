import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'support/project_source_fixture.dart';

const privateReasoning = 'PRIVATE_REASONING_NOT_SOURCE';
const instruction =
    'Keep every requested feature: score, restart and all screens. [maaso_mode:low_latency_voice] is quoted story text.';
String delta(String text) =>
    'event: reply.delta\ndata: ${jsonEncode({'delta': text})}\n\n';
const headers = {
  'content-type': 'text/event-stream; charset=utf-8',
  'x-maaso-output-format': 'json_object',
  'x-maaso-generation-mode': 'project_source',
};
http.Response success(Object value) => http.Response(
  '${delta(jsonEncode(value))}event: completion\ndata: {"finishReason":"stop","status":"complete"}\n\nevent: done\ndata: [DONE]\n\n',
  200,
  headers: headers,
);
String partialChunk(String id, String fragment, {String prefix = ''}) {
  final bindings = jsonEncode({
    'fileId': id,
    'baseCursor': utf8.encode(prefix).length,
    'prefixHash': sourceWorkspaceDigest(prefix),
  });
  final append = jsonEncode(fragment);
  return '${bindings.substring(0, bindings.length - 1)},"append":${append.substring(0, append.length - 1)}';
}

http.Response length(String visible) => http.Response(
  '${delta(visible)}event: trace\ndata: ${jsonEncode({'reasoning_content': privateReasoning})}\n\nevent: completion\ndata: {"finishReason":"length","status":"truncated"}\n\n',
  200,
  headers: headers,
);

class Harness {
  Harness(this.responses) {
    client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test'),
      model: 'synthetic',
      accessTokenProvider: () async => 'synthetic',
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        expect(body['generationMode'], 'project_source');
        expect(body['outputFormat'], 'json_object');
        expect(body.containsKey('maxTokens'), isFalse);
        expect(ids.add(body['turnId'] as String), isTrue);
        final messages = body['messages'] as List;
        expect(messages.map((m) => m['role']), ['system', 'user']);
        expect(messages.last['content'], instruction);
        expect(request.body, isNot(contains(privateReasoning)));
        expect(request.body, isNot(contains('COMPACT DRAFT MODE')));
        return responses.removeAt(0);
      }),
    );
  }
  final List<http.Response> responses;
  late final MaasoThinProxyLLMClient client;
  final requests = <Map<String, dynamic>>[];
  final ids = <String>{};
  final checkpoints = <GeneratedTaskCheckpoint>[];
  final drafts = <SourceWorkspaceSnapshot>[];
  GeneratedGameArtifact producer() => GeneratedGameArtifact(
    client: client,
    instruction: instruction,
    surfaceId: 'game-host-authority',
    zh: false,
    onCheckpoint: (checkpoint, {publicSummary}) => checkpoints.add(checkpoint),
    onDraft: drafts.add,
  );
  String prompt(int i) =>
      (requests[i]['messages'] as List).first['content'] as String;
}

void verify(dynamic envelope, {String html = sourceHtml}) {
  expect(envelope.actions, hasLength(1));
  expect(envelope.actions.single.type, 'surface.show');
  final surface = SurfaceProject.fromJson(
    envelope.actions.single['surface'] as Map,
  );
  expect(surface.id, 'game-host-authority');
  expect(surface.kind, SurfaceKind.fullscreen);
  expect(surface.rendering, SurfaceRendering.webApp);
  expect(surface.experienceType, SurfaceExperienceType.game);
  expect(surface.manifest.actions, isEmpty);
  expect(surface.manifest.events.map((e) => e.name), [
    'game.state',
    'game.event',
  ]);
  expect(surface.html, html);
  expect(surface.css, sourceCss);
  expect(surface.js, sourceJs);
  expect(jsonEncode(envelope.toJson()), isNot(contains(privateReasoning)));
  SurfaceProjectValidator.validateForPublicGame(surface);
}

void main() {
  test(
    'HTTP source length continues the same file with visible UTF8 cursor and no quality reduction',
    () async {
      final html = sourceHtml.replaceFirst('Tap score', '计分😀');
      final split = html.indexOf('</h1>');
      final prefix = html.substring(0, split), suffix = html.substring(split);
      final h = Harness([
        success(sourcePlan),
        length(partialChunk('screen.html', prefix)),
        success(boundSourceChunk('screen.html', suffix, prefix: prefix)),
        success(boundSourceChunk('skin.css', sourceCss)),
        success(boundSourceChunk('game.js', sourceJs)),
      ]);
      final envelope = await h.producer().generate();
      expect(h.requests, hasLength(5));
      verify(envelope, html: html);
      expect(h.prompt(2), contains(jsonEncode(prefix)));
      expect(
        h.prompt(2),
        contains('"baseCursor":${utf8.encode(prefix).length}'),
      );
      expect(h.prompt(2), contains(sourceWorkspaceDigest(prefix)));
      expect(h.prompt(2), isNot(contains('js <= 1800')));
      expect(
        h.checkpoints,
        contains(GeneratedTaskCheckpoint.sourceContinuation),
      );
      expect(
        h.checkpoints.map((checkpoint) => checkpoint.name),
        isNot(contains('outputReduction')),
      );
      expect(
        h.drafts.any(
          (d) => d.files.any(
            (f) =>
                f.plan.id == 'screen.html' && f.source == prefix && !f.complete,
          ),
        ),
        isTrue,
      );
      expect(h.drafts.last.files.every((f) => f.complete), isTrue);
    },
  );
  test(
    'logic length keeps accepted layout bytes and continues only its JS binding',
    () async {
      final prefix = sourceJs.substring(0, 80), suffix = sourceJs.substring(80);
      final h = Harness([
        success(sourcePlan),
        success(boundSourceChunk('screen.html', sourceHtml)),
        success(boundSourceChunk('skin.css', sourceCss)),
        length(partialChunk('game.js', prefix)),
        success(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      final envelope = await h.producer().generate();
      verify(envelope);
      expect(h.requests, hasLength(5));
      expect(h.prompt(4), contains('"fileId":"game.js"'));
      expect(
        h.prompt(4),
        contains('"baseCursor":${utf8.encode(prefix).length}'),
      );
      expect(h.prompt(4), contains(sourceWorkspaceDigest(prefix)));
      expect(h.prompt(4), contains(jsonEncode(prefix)));
      final before = h.drafts.firstWhere(
        (d) => d.files.any((f) => f.plan.id == 'game.js' && f.source == prefix),
      );
      final after = h.drafts.last;
      for (final id in ['screen.html', 'skin.css']) {
        final a = before.files.singleWhere((f) => f.plan.id == id),
            b = after.files.singleWhere((f) => f.plan.id == id);
        expect(utf8.encode(b.source), utf8.encode(a.source));
        expect(b.chunkDigests, a.chunkDigests);
      }
    },
  );
  test('HTTP unsupported source mode never falls back or replays', () async {
    final h = Harness([
      http.Response(
        jsonEncode({
          'code': 'GENERATION_MODE_UNSUPPORTED',
          'message': privateReasoning,
        }),
        400,
      ),
    ]);
    await expectLater(
      h.producer().generate(),
      throwsA(
        isA<LLMResponseIntegrityException>().having(
          (e) => e.runtimeReason,
          'code',
          'generated_task_failure:structuredOutputUnsupported',
        ),
      ),
    );
    expect(h.requests, hasLength(1));
    expect(h.checkpoints, [GeneratedTaskCheckpoint.sourcePlanning]);
    expect(
      h.drafts.map((draft) => draft.executionDigest).toSet(),
      hasLength(1),
    );
    expect(
      h.drafts.every((draft) => draft.blueprint == null && draft.files.isEmpty),
      isTrue,
    );
    final pending = h.drafts.first.executionCheckpoint!;
    expect(pending.requestPending, isTrue);
    expect(pending.systemPrompt, h.prompt(0));
    expect(
      h.drafts.last.executionCheckpoint!.requestDigest,
      pending.requestDigest,
    );
    expect(
      h.drafts.last.diagnostic!.reason,
      SourceDiagnosticReason.providerFailure,
    );
    expect(
      jsonEncode(h.drafts.map((draft) => draft.toJson()).toList()),
      isNot(contains(privateReasoning)),
    );
  });
  test(
    'HTTP authentication failure never continues a source candidate',
    () async {
      final h = Harness([
        http.Response(
          jsonEncode({
            'code': 'AUTHENTICATION_REQUIRED',
            'message': privateReasoning,
          }),
          401,
        ),
      ]);
      await expectLater(
        h.producer().generate(),
        throwsA(
          isA<HostedLLMFailure>().having(
            (e) => e.kind,
            'kind',
            HostedLLMFailureKind.authentication,
          ),
        ),
      );
      expect(h.requests, hasLength(1));
      expect(
        h.drafts.map((draft) => draft.executionDigest).toSet(),
        hasLength(1),
      );
      expect(
        h.drafts.every(
          (draft) => draft.blueprint == null && draft.files.isEmpty,
        ),
        isTrue,
      );
      final pending = h.drafts.first.executionCheckpoint!;
      expect(pending.requestPending, isTrue);
      expect(pending.systemPrompt, h.prompt(0));
      expect(
        h.drafts.last.executionCheckpoint!.requestDigest,
        pending.requestDigest,
      );
      expect(
        h.drafts.last.diagnostic!.reason,
        SourceDiagnosticReason.providerFailure,
      );
      expect(
        jsonEncode(h.drafts.map((draft) => draft.toJson()).toList()),
        isNot(contains(privateReasoning)),
      );
    },
  );
  test(
    'generation credit shortage keeps prior draft without model replay',
    () async {
      final h = Harness([
        success(sourcePlan),
        success(boundSourceChunk('screen.html', sourceHtml)),
        http.Response(
          jsonEncode({'code': 'GENERATION_CREDIT_INSUFFICIENT'}),
          429,
        ),
      ]);
      await expectLater(
        h.producer().generate(),
        throwsA(
          isA<LLMResponseIntegrityException>().having(
            (e) => e.runtimeReason,
            'code',
            'generated_task_failure:generationCreditInsufficient',
          ),
        ),
      );
      expect(h.requests, hasLength(3));
      expect(
        h.drafts.last.files
            .singleWhere((f) => f.plan.id == 'screen.html')
            .source,
        sourceHtml,
      );
      expect(
        h.drafts.last.files
            .singleWhere((f) => f.plan.id == 'screen.html')
            .complete,
        isTrue,
      );
    },
  );
}
