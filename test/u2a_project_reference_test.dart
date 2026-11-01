import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_turn_input.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';
import 'package:sembast/sembast.dart';
import 'project_build_reference_chain_test.dart' as references;

// Controller handoff uses real media/selection persistence. The runtime records
// the handoff and persists chat through its real turn controller; this is not
// evidence of model generation. Runtime generation is tested separately.
class ReferenceFixture extends references.ReferenceHarness {
  @override
  String get appletScope => 'device-legacy';
}

class RecordingRuntime extends AgentRuntime {
  RecordingRuntime(AgentProfile profile)
    : super(agentId: 'self', profile: profile, llmClient: UnusedModel()) {
    manager = ConversationTurnController(
      agentId: 'self',
      runChat: (context, _) async {
        receivedScopes.add(context.expectedAppletScopeKey);
        dispatches++;
        await checkPersisted?.call();
        return ExecutionResult.success('已收到请求');
      },
      stopOutput: () async {},
      isAvailable: () => true,
      briefPause: Duration.zero,
      invitationPause: Duration.zero,
    );
  }
  late final ConversationTurnController manager;
  bool conversation = true;
  int dispatches = 0;
  final selections = <ProjectReferenceSelection?>[],
      inputs = <ProjectReferenceInputSnapshot?>[],
      receivedScopes = <String?>[];
  Future<void> Function()? checkPersisted;
  @override
  bool get usesConversationTurns => conversation;
  @override
  T withProjectReferenceInput<T>(
    ProjectReferenceInputSnapshot? input,
    T Function() operation, {
    bool hasReferenceMedia = false,
    ProjectReferenceSelection? referenceSelection,
    ProjectBuildEditTarget? editTarget,
    bool Function()? editIsCurrent,
    void Function()? onEditQueued,
  }) {
    expect(hasReferenceMedia, isTrue);
    selections.add(referenceSelection);
    inputs.add(input);
    return super.withProjectReferenceInput(
      input,
      operation,
      hasReferenceMedia: hasReferenceMedia,
      referenceSelection: referenceSelection,
      editTarget: editTarget,
      editIsCurrent: editIsCurrent,
      onEditQueued: onEditQueued,
    );
  }

  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) async {
    receivedScopes.add(expectedAppletScopeKey);
    dispatches++;
    await checkPersisted?.call();
    return ExecutionResult.success('已收到请求');
  }

  @override
  ConversationTurnHandle submitConversation(
    String text, {
    required DBService database,
    String? sessionId,
    TurnOrigin origin = TurnOrigin.user,
    String? submissionToken,
    String? expectedAppletScopeKey,
    List<Message> extraContext = const [],
    List<ChatAttachment> attachments = const [],
    String? visualContext,
    void Function(ChatMessage)? onMessage,
    bool respondImmediately = false,
    bool allowInputMerge = true,
    AppInvocationTurnInput? invocation,
    AppInvocationRecoveryInput? recovery,
    bool Function()? spokenRepliesAllowed,
    Future<void>? onSpeechRevoked,
  }) => manager.submit(
    text,
    database: database,
    sessionId: sessionId,
    origin: origin,
    submissionToken: submissionToken,
    expectedAppletScopeKey: expectedAppletScopeKey,
    extraContext: extraContext,
    attachments: attachments,
    visualContext: visualContext,
    onMessage: onMessage,
    respondImmediately: respondImmediately,
    allowInputMerge: allowInputMerge,
  );
  @override
  Future<void> interruptConversation() => manager.cancelCurrent();
  @override
  void updateConversationDraft(String text) => manager.updateDraft(text);
}

class UnusedModel extends LLMClient {
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('no_model_expected');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('no_model_expected');
}

class RecordingRegistry extends AgentRuntimeRegistry {
  RecordingRegistry(this.runtime);
  final AgentRuntime runtime;
  bool host = true;
  Completer<void>? entered, release;
  @override
  bool get canHostExecution => host;
  @override
  AgentRuntime? get(String agentId) => runtime;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async {
    entered?.complete();
    await release?.future;
    return runtime;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReferenceFixture h;
  late RecordingRuntime runtime;
  late RecordingRegistry registry;
  late U2aChatController chat;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    h = ReferenceFixture();
    await h.init();
    final profile = AgentProfile(
      nickname: 'Test',
      avatar: '',
      bio: '',
      personalityTraits: [],
      catchphrase: '',
    );
    await h.db.saveAgentProfile(profile);
    runtime = RecordingRuntime(profile);
    registry = RecordingRegistry(runtime);
    appServices.put<DBService>(h.db);
    appServices.put(h.jobs);
    appServices.put(h.tasks);
    appServices.put<ChatMediaService>(h.media);
    appServices.put<AgentRuntimeRegistry>(registry);
    chat = appServices.put(U2aChatController());
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() async {
    await appServices.delete<U2aChatController>(force: true);
    await runtime.manager.retireAndDrain();
    runtime.dispose();
    await h.close();
    await appServices.reset();
  });
  for (final conversation in [true, false]) {
    test(
      '${conversation ? 'conversation' : 'legacy chat'} receives persisted reference selection without fabricated summary',
      () async {
        runtime.conversation = conversation;
        final image = references.picture(90);
        chat.pendingMedia.add(image);
        chat.inputController.text = '参考这张图帮我制作一个待办清单小程序';
        runtime.checkPersisted = () async {
          final selected = runtime.selections.single!;
          expect(selected.references.single.sha256, image.attachment.id);
          expect(
            await stringMapStoreFactory
                .store('chat_media.v1')
                .record(image.attachment.id)
                .exists(h.db.raw),
            isTrue,
          );
          expect(
            await stringMapStoreFactory
                .store('project_build_reference_selections.v1')
                .count(h.db.raw),
            1,
          );
        };
        await chat.sendMessage();
        expect(runtime.dispatches, 1);
        expect(runtime.inputs.single, isNull);
        expect(h.analyses, 0);
        expect(h.uploads, isEmpty);
        expect(runtime.receivedScopes, ['device-legacy']);
        expect(chat.pendingMedia, isEmpty);
        final rows = await h.db.getMessages('self');
        final user = rows.singleWhere((r) => r.isUserMessage);
        expect(user.visualContext, isNull);
        expect(user.attachments.single.id, image.attachment.id);
      },
    );
  }
  test(
    'same request text with a newly selected picture has a new source identity',
    () async {
      runtime.conversation = false;
      for (final color in [20, 200]) {
        chat.pendingMedia.add(references.picture(color));
        chat.inputController.text = '帮我制作一个待办清单小程序';
        await chat.sendMessage();
      }
      expect(runtime.selections, hasLength(2));
      expect(
        runtime.selections[0]!.sourceIdentityDigest,
        isNot(runtime.selections[1]!.sourceIdentityDigest),
      );
      expect(h.analyses, 0);
    },
  );
  test(
    'remote generation keeps text and media without sending local references or inventing observations',
    () async {
      registry.host = false;
      chat.pendingMedia.add(references.picture(30));
      chat.inputController.text = '帮我制作一个待办清单小程序';
      await chat.sendMessage();
      expect(runtime.dispatches, 0);
      expect(h.analyses, 0);
      expect(h.uploads, isEmpty);
      expect(chat.pendingMedia, hasLength(1));
      expect(chat.inputController.text, contains('待办'));
      expect(chat.sendError.value, isNotNull);
    },
  );
  for (final interrupt in ['stop', 'retire', 'remote']) {
    test(
      '$interrupt while runtime attaches cannot deliver an old reference turn',
      () async {
        registry.entered = Completer<void>();
        registry.release = Completer<void>();
        chat.pendingMedia.add(references.picture(40));
        chat.inputController.text = '帮我制作一个待办清单小程序';
        final sending = chat.sendMessage();
        await registry.entered!.future;
        if (interrupt == 'stop') {
          chat.interruptCurrent();
        } else if (interrupt == 'retire') {
          h.current = false;
        } else {
          registry.host = false;
        }
        registry.release!.complete();
        await sending;
        expect(runtime.dispatches, 0);
        expect(h.uploads, isEmpty);
        expect(chat.pendingMedia, hasLength(1));
        expect(await h.db.getMessages('self'), isEmpty);
      },
    );
  }
  test(
    'local capture failure preserves the exact selection for retry',
    () async {
      final image = references.picture(50);
      chat.pendingMedia.add(
        PreparedChatMedia(image.attachment, image.bytes.sublist(1), image.mime),
      );
      chat.inputController.text = '帮我制作一个待办清单小程序';
      await chat.sendMessage();
      expect(runtime.dispatches, 0);
      expect(chat.pendingMedia, hasLength(1));
      expect(chat.inputController.text, contains('待办'));
      expect(h.analyses, 0);
      expect(chat.sendError.value, isNotNull);
    },
  );
}
