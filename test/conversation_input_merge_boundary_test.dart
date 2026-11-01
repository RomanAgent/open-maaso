import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';
import 'package:sembast/sembast_memory.dart';

import 'project_build_v2_delivery_test.dart' as delivery;
import 'project_build_v2_edit_target_test.dart' as editing;
import 'project_build_v2_management_test.dart' as management;

const _deadline = Duration(seconds: 3);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('conversation merge boundary', () {
    late DBService database;
    ConversationTurnController? controller;

    setUp(() async {
      await appServices.reset();
      database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'merge-boundary-${DateTime.now().microsecondsSinceEpoch}.db',
      );
    });
    tearDown(() async {
      await controller?.retireAndDrain().timeout(_deadline);
      controller = null;
      await database.close();
      await appServices.reset();
    });

    for (final flags in [
      (true, true),
      (true, false),
      (false, true),
      (false, false),
    ]) {
      test(
        'previous=${flags.$1}, incoming=${flags.$2} requires both to merge',
        () async {
          final generated = <String>[];
          var stops = 0;
          controller = ConversationTurnController(
            agentId: 'self',
            isAvailable: () => true,
            stopOutput: () async => stops++,
            inputMergeWindow: const Duration(seconds: 1),
            runChat: (context, history) async {
              generated.add(context.text);
              return ExecutionResult.success('answer');
            },
          );
          final first = controller!.submit(
            'first',
            database: database,
            allowInputMerge: flags.$1,
          );
          final second = controller!.submit(
            'second',
            database: database,
            allowInputMerge: flags.$2,
          );
          controller!.flushPendingInput();
          final results = await Future.wait([
            first.done,
            second.done,
          ]).timeout(_deadline);
          final merged = flags.$1 && flags.$2;
          expect(first.turnId == second.turnId, merged);
          expect(results.first.cancelled, !merged);
          expect(results.last.cancelled, isFalse);
          expect(generated, merged ? ['first\nsecond'] : ['second']);
          expect(stops, merged ? 1 : 2);
          final rows = await database.getMessages('self');
          final users = rows.where((row) => row.isUserMessage).toList();
          expect(users.map((row) => row.content), ['first', 'second']);
          expect(
            users.map((row) => row.turnId).toSet(),
            hasLength(merged ? 1 : 2),
          );
          expect(rows.where((row) => !row.isUserMessage), hasLength(1));
        },
      );
    }
  });

  group('runtime edit inputs across merge boundaries', () {
    late delivery.Harness harness;
    late _BindingRecordingRuntime runtime;
    late ProjectBuildEditTarget target;

    setUp(() async {
      await appServices.reset();
      appServices.testMode = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
            call,
          ) async {
            if (call.method == 'getLanguages') return <String>['en-US'];
            if (call.method == 'getVoices') return <Object>[];
            return 1;
          });
      harness = delivery.Harness(
        appletScope: AppletLocalOwnership.currentScopeKey(),
      );
      await harness.init();
      management.setRemote(harness, 2);
      target = await editing.target(harness);
      appServices.put(harness.db);
      runtime = _BindingRecordingRuntime();
    });
    tearDown(() async {
      await runtime.retireAndDrain().timeout(_deadline);
      runtime.dispose();
      await harness.close();
      await appServices.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
    });

    ConversationTurnHandle submitEdit(String text) =>
        runtime.withProjectReferenceInput(
          null,
          () => runtime.submitConversation(
            text,
            database: harness.db,
            expectedAppletScopeKey: target.appletScopeKey,
          ),
          editTarget: target,
          editIsCurrent: () => target.isCurrent,
        );

    test(
      'control: actual runtime restores selected edit input for its own turn',
      () async {
        final selected = submitEdit('typed edit');
        runtime.flushPendingConversationInput();
        final result = await selected.done.timeout(_deadline);
        expect(result.cancelled, isFalse);
        expect(runtime.generatedTexts, ['typed edit']);
        expect(runtime.generatedEditTargets.single, same(target));
      },
    );

    test(
      'voice does not inherit a typed edit still waiting in the merge window',
      () async {
        final selected = submitEdit('typed edit');
        final voice = runtime.submitConversation(
          'voice utterance',
          database: harness.db,
          expectedAppletScopeKey: target.appletScopeKey,
          allowInputMerge: false,
        );
        runtime.flushPendingConversationInput();
        final results = await Future.wait([
          selected.done,
          voice.done,
        ]).timeout(_deadline);
        expect(selected.turnId, isNot(voice.turnId));
        expect(results.first.cancelled, isTrue);
        expect(results.last.cancelled, isFalse);
        expect(runtime.generatedTexts, ['voice utterance']);
        expect(runtime.generatedEditTargets, [null]);
        expect(target.isCurrent, isTrue);
        final users = (await harness.db.getMessages(
          'self',
        )).where((row) => row.isUserMessage);
        expect(users.map((row) => row.content), [
          'typed edit',
          'voice utterance',
        ]);
        expect(users.map((row) => row.turnId).toSet(), hasLength(2));
      },
    );

    test(
      'later default typed edit cannot merge into a voice context',
      () async {
        final voice = runtime.submitConversation(
          'voice utterance',
          database: harness.db,
          expectedAppletScopeKey: target.appletScopeKey,
          allowInputMerge: false,
        );
        final selected = submitEdit('later typed edit');
        runtime.flushPendingConversationInput();
        final results = await Future.wait([
          voice.done,
          selected.done,
        ]).timeout(_deadline);
        expect(voice.turnId, isNot(selected.turnId));
        expect(results.first.cancelled, isTrue);
        expect(results.last.cancelled, isFalse);
        expect(runtime.generatedTexts, ['later typed edit']);
        expect(runtime.generatedEditTargets.single, same(target));
      },
    );

    test(
      'ordinary default typed submissions still share one runtime turn',
      () async {
        final first = runtime.submitConversation(
          'first typed',
          database: harness.db,
        );
        final second = runtime.submitConversation(
          'second typed',
          database: harness.db,
        );
        runtime.flushPendingConversationInput();
        final results = await Future.wait([
          first.done,
          second.done,
        ]).timeout(_deadline);
        expect(first.turnId, second.turnId);
        expect(results.every((result) => !result.cancelled), isTrue);
        expect(runtime.generatedTexts, ['first typed\nsecond typed']);
        expect(runtime.generatedEditTargets, [null]);
      },
    );
  });
}

// Keeps production submitConversation, its turnId-keyed edit map and queue.
// Only the generation leaf is replaced, and the existing binding boundary is
// observed to prove which edit target the real runtime supplies to that leaf.
class _BindingRecordingRuntime extends AgentRuntime {
  _BindingRecordingRuntime()
    : super(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
        llmClient: _UnusedModel(),
        conversationDeliveryMode: ConversationDeliveryMode.text,
        prepareTtsForNewTurn: (_) async {},
      );

  final boundTargets = <ProjectBuildEditTarget?>[];
  final generatedTexts = <String>[];
  final generatedEditTargets = <ProjectBuildEditTarget?>[];

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
    boundTargets.add(editTarget);
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
    generatedTexts.add(text);
    generatedEditTargets.add(boundTargets.last);
    return ExecutionResult.success('answer');
  }
}

class _UnusedModel implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
