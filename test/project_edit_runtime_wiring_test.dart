import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'project_build_reference_chain_test.dart' show ReferenceHarness, picture;
import 'project_build_v2_edit_target_test.dart' as edit_fixture;
import 'project_build_v2_management_test.dart' as management;

class _References extends ReferenceHarness {
  @override
  String get appletScope => AppletLocalOwnership.currentScopeKey();
  final editPosts = <Map<String, Object?>>[];
  @override
  Future<http.Response> referenceHTTP(http.Request request) {
    if (request.url.path.endsWith('/projects') ||
        request.url.path.contains('/projects/')) {
      return handle(request);
    }
    if (request.method == 'POST' &&
        request.url.path == '/v1/project-builds/v2') {
      editPosts.add(projectBuildV2Object(jsonDecode(request.body)));
      // The test stops at actual transport dispatch. It does not fabricate a
      // successful server receipt or a model-generated edited project.
      return Future.value(http.Response('{}', 503));
    }
    return super.referenceHTTP(request);
  }
}

class _NoModel implements LLMClient {
  int calls = 0;
  bool answer = false;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    if (answer) return '{"reply":"I will not modify it.","actions":[]}';
    throw StateError('Unexpected main-chat model call');
  }

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await chat(messages, timeout: timeout);
    yield const LLMStreamEvent(
      event: 'reply.delta',
      data: '{"delta":"I will not modify it."}',
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Registry extends AgentRuntimeRegistry {
  _Registry(this.runtime);
  final AgentRuntime runtime;
  @override
  AgentRuntime? get(String id) => id == runtime.agentId ? runtime : null;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async => runtime;
}

class _Core extends AgentCoreController {
  _Core(this.value);
  final AgentProfile value;
  @override
  // ignore: must_call_super
  void onInit() {
    profile.value = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return <String>['en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  late _References h;
  late _NoModel model;
  late AgentRuntime runtime;
  late HomeController home;
  var useConversation = true;
  late bool previousSound;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    previousSound = MaasoTtsPlugin.soundEnabled.value;
    MaasoTtsPlugin.soundEnabled.value = false;
    h = _References();
    await h.init();
    management.setRemote(h, 2);
    appServices.put(h.db);
    appServices.put(h.jobs);
    appServices.put(h.media);
    appServices.put(h.tasks);
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.proxyDefault;
    model = _NoModel();
    final profile = AgentProfile(
      nickname: 'Maaso',
      avatar: '',
      bio: '',
      personalityTraits: const [],
      catchphrase: '',
    );
    runtime = AgentRuntime(
      agentId: 'self',
      profile: profile,
      llmClient: model,
      prepareTtsForNewTurn: (_) async {},
      conversationDeliveryModeProvider: () => useConversation
          ? ConversationDeliveryMode.text
          : ConversationDeliveryMode.legacy,
    );
    await runtime.init();
    appServices.put<AgentRuntimeRegistry>(_Registry(runtime));
    appServices.put<AgentCoreController>(_Core(profile));
    home = appServices.put(HomeController());
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    await appServices.delete<HomeController>(force: true);
    await runtime.retireAndDrain();
    runtime.dispose();
    clearAppletEditReference();
    await h.close();
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = previousSound;
    useConversation = true;
  });

  Future<ProjectBuildEditTarget> select() async {
    final target = await edit_fixture.target(h);
    final intent = HomeDraftIntent.projectBuildEditing(target);
    expect(
      intent.consume(currentScopeKey: 'foreign', existingDraft: 'keep'),
      isNull,
    );
    // Fresh intent is required after a rejected replay/scope; plain game draft
    // behavior remains covered separately.
    final native = HomeDraftIntent.projectBuildEditing(
      target,
    ).consumeProjectBuildEdit(currentScopeKey: h.appletScope);
    expect(native, same(target));
    expect(home.beginProjectBuildEditing(native!), isTrue);
    return target;
  }

  Future<void> synchronized() async {
    for (final job in h.jobs.jobs.toList()) {
      await h.tasks.synchronize(job.taskId);
    }
  }

  for (final conversation in [true, false]) {
    test(
      'actual ${conversation ? 'conversation' : 'legacy'} Home edit with image sends original project/revision/head CAS',
      () async {
        useConversation = conversation;
        final target = await select();
        final image = picture(123);
        home.pendingMedia.add(image);
        home.inputController.text = '把背景改成图片里的蓝色，保留已有清单数据';
        await home.send();
        expect(h.jobs.jobs, hasLength(1));
        await synchronized();
        expect(h.editPosts, isNotEmpty);
        final sent = h.editPosts.first;
        expect(sent['projectId'], target.projectId);
        expect(sent['baseRevision'], target.baseRevision);
        expect(sent['baseHeadVersion'], target.baseHeadVersion);
        expect(sent['agentId'], 'self');
        expect(sent['requirements'], contains('保留已有清单数据'));
        expect(sent['referenceInputs'], hasLength(1));
        expect(h.analyses, 0);
        expect(model.calls, 0);
        expect(
          h.jobs.jobs.single.projectBuildV2!.editIdentity,
          target.identity,
        );
        expect(home.pendingMedia, isEmpty);
        expect(home.projectBuildEditTarget.value, isNull);
        final cached = await h.media.read(image.attachment);
        expect(cached!.bytes, image.bytes);
      },
    );
  }

  test(
    'same request against a different pinned head is not a duplicate edit',
    () async {
      await select();
      home.inputController.text = '把按钮改成蓝色';
      await home.send();
      expect(h.jobs.jobs, hasLength(1));
      final first = h.jobs.jobs.single.projectBuildV2!.editIdentity!;
      management.setRemote(h, 3);
      final next = await select();
      home.inputController.text = '把按钮改成蓝色';
      await home.send();
      expect(h.jobs.jobs, hasLength(2));
      expect(next.identity.digest, isNot(first.digest));
      expect(h.jobs.jobs.last.projectBuildV2!.editIdentity, next.identity);
      expect(model.calls, 0);
    },
  );
  for (final conversation in [true, false]) {
    test(
      '${conversation ? 'conversation' : 'legacy'} changed head retains images and never creates a different base',
      () async {
        useConversation = conversation;
        await select();
        final image = picture(124);
        home.pendingMedia.add(image);
        home.inputController.text = '把按钮改成蓝色';
        management.setRemote(h, 3);
        await home.send();
        expect(h.jobs.jobs, isEmpty);
        expect(h.editPosts, isEmpty);
        expect(h.uploads, isEmpty);
        expect(home.pendingMedia, hasLength(1));
        expect(home.inputController.text, '把按钮改成蓝色');
      },
    );
  }
  test(
    'cancel selected edit preserves draft and images without submitting',
    () async {
      await select();
      home.inputController.text = 'retain this draft';
      home.pendingMedia.add(picture(125));
      home.clearProjectBuildEditTarget();
      expect(home.projectBuildEditTarget.value, isNull);
      expect(home.pendingMedia, hasLength(1));
      expect(home.inputController.text, 'retain this draft');
      expect(h.jobs.jobs, isEmpty);
      expect(h.editPosts, isEmpty);
    },
  );
  test(
    'selecting a legacy edit target clears the V2 context without dropping draft',
    () async {
      await select();
      home.inputController.text = 'keep this draft';
      appletEditReference.value = AppletEditReference(
        item: AgentWidget(
          id: 900,
          agentId: 'self',
          title: 'Legacy',
          kind: 'surface',
          createdAt: DateTime.now(),
          spec: {
            'surfaceId': 'legacy-target',
            'experienceType': 'utility',
            'html': '<main>legacy</main>',
          },
        ),
        scopeKey: h.appletScope,
      );
      await Future<void>.delayed(Duration.zero);
      expect(home.projectBuildEditTarget.value, isNull);
      expect(home.inputController.text, 'keep this draft');
      expect(h.jobs.jobs, isEmpty);
    },
  );
  test(
    'explicitly declined edits remain discussion despite a selected native target',
    () async {
      await select();
      model.answer = true;
      home.inputController.text = '不要生成或修改这个小程序，只解释操作方式';
      await home.send();
      expect(h.jobs.jobs, isEmpty);
      expect(h.editPosts, isEmpty);
      expect(home.projectBuildEditTarget.value, isNotNull);
    },
  );
}
