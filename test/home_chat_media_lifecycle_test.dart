import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/chat/presentation/media/chat_attachment_preview.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_gateway.dart';
import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;
import 'project_build_v2_delivery_test.dart' as delivery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  late ChatMediaService media;
  late Future<http.Response> Function(http.Request) respond;
  var calls = 0;
  http.Response success(http.Request request) => http.Response(
    jsonEncode({
      'code': 'OK',
      'data': {
        'description': 'A cup',
        'sourceMediaIds': (jsonDecode(request.body)['media'] as List)
            .map((e) => e['id'])
            .toList(),
      },
    }),
    200,
  );
  PreparedChatMedia prepared() => normalizeChatImage(
    Uint8List.fromList(image.encodePng(image.Image(width: 32, height: 32))),
  );
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    calls = 0;
    respond = (r) async => success(r);
    harness = await ConversationEntryHarness.create();
    media = appServices.put(
      ChatMediaService(
        database: harness.database.raw,
        isCurrent: () => true,
        baseUri: Uri.parse('https://example.invalid/'),
        accessToken: () async => 'test',
        client: MockClient((r) {
          calls++;
          return respond(r);
        }),
      ),
    );
  });
  tearDown(() async => harness.close());
  test(
    'home game with enabled V2 analyzes and persists original summary without raw capture',
    () async {
      final backend = delivery.Harness();
      await backend.init(enabled: true);
      await backend.tasks.deactivateAndDrain();
      var rawCaptures = 0;
      backend.tasks = ProjectBuildV2Tasks(
        jobs: backend.jobs,
        repository: backend.repo,
        gateway: HttpProjectBuildV2Gateway(
          baseUri: () => Uri.parse('https://example.invalid/'),
          contextKey: () => delivery.scope,
          accessToken: () async => 'synthetic',
          isCurrent: () => backend.current,
          client: MockClient(backend.handle),
        ),
        scopeKey: delivery.scope,
        appletScopeKey: backend.appletScope,
        isCurrent: () => backend.current,
        authorize: () async {},
        enableCreation: true,
        referenceMedia: () {
          rawCaptures++;
          throw TestFailure('A game must not capture raw V2 references');
        },
        installation: backend.installations,
        verification: backend.verifier,
        presentCandidate: (_, _, _) async => false,
        persistInstalled: (_, _) async {},
      );
      final builds = appServices.put(backend.tasks);
      addTearDown(backend.close);
      expect(builds.enableCreation, isTrue);
      expect(builds.canSubmit, isTrue);
      final item = prepared();
      var sawSnapshot = false;
      harness.runtime.runChat = (_, _) async {
        final rows = await stringMapStoreFactory
            .store('project_reference_inputs.v1')
            .find(harness.database.raw);
        expect(rows, hasLength(1));
        final snapshot = rows.single.value;
        expect(snapshot['visualSummary'], 'A cup');
        expect(snapshot['inputRevision'], 1);
        final reference = (snapshot['references']! as List).single as Map;
        expect(reference['sha256'], item.attachment.id);
        expect(reference['purpose'], 'reference');
        expect((await media.read(item.attachment))!.bytes, item.bytes);
        sawSnapshot = true;
        return ExecutionResult.success('ok');
      };
      harness.home.pendingMedia.add(item);
      harness.input('home').text = '根据这张图创建一个小游戏';
      await harness.send('home');
      expect(sawSnapshot, isTrue);
      expect(harness.home.pendingMedia, isEmpty);
      expect(calls, 1);
      expect(rawCaptures, 0);
      expect(backend.posts, isEmpty);
    },
  );
  for (final entry in ['home', 'chat']) {
    List<PreparedChatMedia> pending() =>
        entry == 'home' ? harness.home.pendingMedia : harness.chat.pendingMedia;
    test(
      '$entry cancelled analysis can be replaced without old finally clearing the new busy state',
      () async {
        final firstEntered = Completer<http.Request>(),
            secondEntered = Completer<http.Request>();
        final firstResult = Completer<http.Response>(),
            secondResult = Completer<http.Response>();
        respond = (r) {
          if (calls == 1) {
            firstEntered.complete(r);
            return firstResult.future;
          }
          secondEntered.complete(r);
          return secondResult.future;
        };
        pending().add(prepared());
        harness.input(entry).text = 'first';
        final first = harness.send(entry);
        final firstRequest = await firstEntered.future;
        harness.stop(entry);
        harness.input(entry).text = 'second';
        final second = harness.send(entry);
        final secondRequest = await secondEntered.future.timeout(
          const Duration(seconds: 3),
        );
        firstResult.complete(success(firstRequest));
        await first;
        expect(harness.busy(entry), isTrue);
        await harness.send(entry);
        expect(calls, 2);
        secondResult.complete(success(secondRequest));
        await second;
        expect(harness.busy(entry), isFalse);
        expect(pending(), isEmpty);
        expect(
          (await harness.database.getMessages(
            'self',
          )).where((m) => m.isUserMessage).map((m) => m.content),
          ['second'],
        );
      },
    );
    test(
      '$entry runtime failure keeps the attachment and human draft for retry',
      () async {
        harness.runtime.runChat = (_, _) async =>
            ExecutionResult.error('provider unavailable');
        pending().add(prepared());
        harness.input(entry).text = 'Look at this';
        await harness.send(entry);
        expect(pending(), hasLength(1));
        expect(harness.input(entry).text, 'Look at this');
        expect(harness.busy(entry), isFalse);
        expect(
          (await harness.database.getMessages(
            'self',
          )).where((m) => !m.isUserMessage),
          isEmpty,
        );
      },
    );
    test(
      '$entry suspended local account retains media and draft without executing',
      () async {
        await appServices.find<AgentRuntimeRegistry>().suspendHostedExecution();
        final item = prepared();
        pending().add(item);
        harness.input(entry).text = 'What is here?';
        await harness.send(entry);
        expect(harness.runtime.submissions, 0);
        expect(pending(), hasLength(1));
        expect(harness.input(entry).text, 'What is here?');
      },
    );
  }

  for (final entry in ['home', 'chat']) {
    test(
      '$entry unavailable legacy runtime retains attachment instead of text-only fallback',
      () async {
        await appServices.delete<HomeController>(force: true);
        await appServices.delete<U2aChatController>(force: true);
        await appServices.delete<AgentRuntimeRegistry>(force: true);
        appServices.put<AgentRuntimeRegistry>(_UnavailableRegistry());
        final item = prepared();
        if (entry == 'home') {
          final controller = appServices.put<HomeController>(
            _UnavailableHome(),
          );
          controller.pendingMedia.add(item);
          controller.inputController.text = 'Describe the photo';
          await controller.send();
          expect(controller.pendingMedia, hasLength(1));
          expect(controller.inputController.text, 'Describe the photo');
        } else {
          final controller = appServices.put(U2aChatController());
          controller.pendingMedia.add(item);
          controller.inputController.text = 'Describe the photo';
          await controller.sendMessage();
          expect(controller.pendingMedia, hasLength(1));
          expect(controller.inputController.text, 'Describe the photo');
        }
        expect(await harness.database.getMessages('self'), isEmpty);
      },
    );
  }

  testWidgets(
    'open attachment releases decoded media and dismisses when its account retires',
    (tester) async {
      final value = prepared();
      await tester.runAsync(() => media.persist(value));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      openChatAttachment(context, value.attachment),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await media.shutdown();
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _UnavailableRegistry extends AgentRuntimeRegistry {
  @override
  AgentRuntime? get(String agentId) => null;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async =>
      throw StateError('unavailable');
}

class _UnavailableHome extends HomeController {
  @override
  // ignore: must_call_super
  void onInit() {}
}
