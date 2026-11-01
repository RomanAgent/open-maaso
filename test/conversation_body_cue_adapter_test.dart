import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_body_cue_adapter.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_coordinator.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  tearDown(appServices.reset);

  test(
    'publication alone and unpublished playback never execute a cue',
    () async {
      final acts = <AvatarAct>[];
      final adapter = _adapter(acts);
      final unit = _unit(0, {'mood': 'calm'});
      adapter.onSpeechStarted(unit);
      await _flush();
      expect(acts, isEmpty);
      adapter.registerPublished(unit);
      await _flush();
      expect(acts, isEmpty);
      adapter.onSpeechStarted(unit);
      await adapter.finish();
      expect(acts.single.mood, 'calm');
    },
  );

  test('text delivery executes the same high-level committed cue', () async {
    final acts = <AvatarAct>[];
    final adapter = _adapter(acts);
    final unit = _unit(0, {'mood': 'comforting', 'gesture': 'none'});
    adapter.registerPublished(unit);
    adapter.onTextDelivered(unit);
    await adapter.finish();
    expect(acts.single.mood, 'comforting');
    expect(acts.single.gesture, 'none');
    expect(acts.single.inferGesture, isFalse);
  });

  test(
    'wrong turn id sequence or duplicate start never replaces committed body',
    () async {
      final acts = <AvatarAct>[];
      final adapter = _adapter(acts);
      final committed = _unit(0, {'mood': 'serious'});
      adapter.registerPublished(committed);
      adapter.onSpeechStarted(_unit(0, {'mood': 'angry'}, turnId: 'other'));
      adapter.onSpeechStarted(
        _unit(0, {'mood': 'angry'}, utteranceId: 'unknown'),
      );
      adapter.onSpeechStarted(
        _unit(1, {'mood': 'angry'}, utteranceId: committed.utteranceId),
      );
      await _flush();
      expect(acts, isEmpty);
      final replacement = _unit(0, {'mood': 'angry'});
      adapter.registerPublished(replacement);
      adapter.onSpeechStarted(replacement);
      adapter.onSpeechStarted(committed);
      adapter.onTextDelivered(committed);
      await adapter.finish();
      expect(acts.map((act) => act.mood), ['serious']);
    },
  );

  test(
    'invalid registrations do not replace host sequence identities',
    () async {
      final acts = <AvatarAct>[];
      final adapter = _adapter(acts);
      for (final unit in [
        _unit(-1, {'mood': 'angry'}),
        _unit(3, {'mood': 'angry'}),
        _unit(0, {'mood': 'angry'}, utteranceId: ''),
        _unit(0, {'mood': 'angry'}, turnId: 'other'),
      ]) {
        adapter.registerPublished(unit);
        adapter.onSpeechStarted(unit);
      }
      final valid = _unit(0, {'mood': 'calm'});
      final collision = _unit(0, {'mood': 'angry'}, utteranceId: 'collision');
      adapter.registerPublished(valid);
      adapter.registerPublished(collision);
      adapter.onSpeechStarted(collision);
      adapter.onSpeechStarted(valid);
      await adapter.finish();
      expect(acts.map((act) => act.mood), ['calm']);
    },
  );

  for (final invalid in <Map<String, Object?>?>[
    null,
    {},
    {'mood': 'unknown_mood'},
    {'mood': 'none', 'gesture': 'none', 'gaze': 'none', 'posture': 'none'},
    {'mood': 'calm', 'gesture': 'unknown_gesture'},
  ]) {
    test(
      'invalid cue $invalid does not consume the two valid cue budget',
      () async {
        final acts = <AvatarAct>[];
        final adapter = _adapter(acts);
        for (final unit in [
          _unit(0, invalid),
          _unit(1, {'mood': 'calm'}),
          _unit(2, {'mood': 'serious'}),
        ]) {
          adapter.registerPublished(unit);
          adapter.onSpeechStarted(unit);
          await _flush();
        }
        await adapter.finish();
        expect(acts.map((act) => act.mood), ['calm', 'serious']);
      },
    );
  }

  test('at most two distinct valid cues execute per turn', () async {
    final acts = <AvatarAct>[];
    final adapter = _adapter(acts);
    for (var sequence = 0; sequence < 3; sequence++) {
      final unit = _unit(sequence, {
        'mood': ['calm', 'serious', 'happy'][sequence],
      });
      adapter.registerPublished(unit);
      adapter.onSpeechStarted(unit);
      await _flush();
    }
    await adapter.finish();
    expect(acts.map((act) => act.mood), ['calm', 'serious']);
  });

  test('changing amplitude duration or style is still the same cue', () async {
    final acts = <AvatarAct>[];
    final adapter = _adapter(acts);
    for (final unit in [
      _unit(0, {'mood': 'calm', 'intensity': 0.4, 'durationMs': 900}),
      _unit(1, {
        'mood': 'calm',
        'intensity': 0.8,
        'durationMs': 1600,
        'style': 'dramatic',
      }),
      _unit(2, {'mood': 'serious'}),
    ]) {
      adapter.registerPublished(unit);
      adapter.onSpeechStarted(unit);
      await _flush();
    }
    await adapter.finish();
    expect(acts.map((act) => act.mood), ['calm', 'serious']);
  });

  test('cancelled or superseded turns ignore late playback starts', () async {
    final acts = <AvatarAct>[];
    var current = true;
    final adapter = _adapter(acts, isCurrent: () => current);
    final unit = _unit(0, {'mood': 'happy'});
    adapter.registerPublished(unit);
    current = false;
    adapter.onSpeechStarted(unit);
    current = true;
    adapter.close();
    adapter.onSpeechStarted(unit);
    adapter.registerPublished(_unit(1, {'mood': 'serious'}));
    await adapter.finish();
    expect(acts, isEmpty);
  });

  test(
    'older synthesis callback cannot regress a newer started sentence',
    () async {
      final acts = <AvatarAct>[];
      final adapter = _adapter(acts);
      final older = _unit(0, {'mood': 'calm'});
      final newer = _unit(1, {'mood': 'serious'});
      adapter.registerPublished(older);
      adapter.registerPublished(newer);
      adapter.onSpeechStarted(newer);
      await _flush();
      adapter.onSpeechStarted(older);
      await adapter.finish();
      expect(acts.map((act) => act.mood), ['serious']);
    },
  );

  test(
    'close releases a hung dispatch and drops a queued second cue',
    () async {
      final entered = Completer<void>();
      final hung = Completer<AvatarBehaviorResult>();
      final acts = <AvatarAct>[];
      bool Function()? firstMayContinue;
      final adapter = ConversationBodyCueAdapter(
        turnId: 'turn',
        isCurrent: () => true,
        applyCue: (act, mayContinue) {
          acts.add(act);
          firstMayContinue = mayContinue;
          entered.complete();
          return hung.future;
        },
      );
      final first = _unit(0, {'mood': 'calm'});
      final second = _unit(1, {'mood': 'serious'});
      adapter.registerPublished(first);
      adapter.registerPublished(second);
      adapter.onSpeechStarted(first);
      await entered.future;
      adapter.onSpeechStarted(second);
      adapter.close();
      expect(firstMayContinue!(), isFalse);
      await adapter.finish().timeout(const Duration(milliseconds: 100));
      expect(acts.map((act) => act.mood), ['calm']);
      hung.completeError(StateError('late renderer failure'));
      await _flush();
    },
  );

  test('optional renderer timeout is bounded and retires late work', () async {
    final entered = Completer<void>();
    final hung = Completer<AvatarBehaviorResult>();
    bool Function()? mayContinue;
    final acts = <AvatarAct>[];
    final adapter = ConversationBodyCueAdapter(
      turnId: 'turn',
      isCurrent: () => true,
      dispatchTimeout: const Duration(milliseconds: 20),
      applyCue: (act, guard) {
        acts.add(act);
        mayContinue = guard;
        entered.complete();
        return hung.future;
      },
    );
    final first = _unit(0, {'mood': 'calm'});
    adapter.registerPublished(first);
    adapter.onSpeechStarted(first);
    await entered.future;
    final second = _unit(1, {'mood': 'serious'});
    adapter.registerPublished(second);
    adapter.onSpeechStarted(second);
    await adapter.finish().timeout(const Duration(milliseconds: 250));
    expect(mayContinue!(), isFalse);
    final late = _unit(2, {'mood': 'happy'});
    adapter.registerPublished(late);
    adapter.onSpeechStarted(late);
    hung.complete(_applied);
    await _flush();
    expect(acts, hasLength(1));
  });

  test('failed cue does not poison following delivery', () async {
    final acts = <AvatarAct>[];
    final adapter = ConversationBodyCueAdapter(
      turnId: 'turn',
      isCurrent: () => true,
      applyCue: (act, _) async {
        acts.add(act);
        if (acts.length == 1) throw StateError('renderer failure');
        return _applied;
      },
    );
    for (final unit in [
      _unit(0, {'mood': 'calm'}),
      _unit(1, {'mood': 'serious'}),
    ]) {
      adapter.registerPublished(unit);
      adapter.onSpeechStarted(unit);
      await _flush();
    }
    await adapter.finish();
    expect(acts.map((act) => act.mood), ['calm', 'serious']);
  });

  for (final retireByNewSentence in [false, true]) {
    test(
      'real director stops after asynchronous gaze when ${retireByNewSentence ? 'next sentence starts' : 'turn is cancelled'}',
      () async {
        final runtime = _CueRuntime();
        final gaze = _DeferredGaze();
        final emotions = <AvatarEmotionIntent>[];
        final director = AvatarBehaviorDirector(
          agentId: 'companion',
          runtimeProvider: () => runtime,
          emitEmotion: emotions.add,
          gazeIntentHandler: gaze,
        );
        final adapter = ConversationBodyCueAdapter(
          turnId: 'turn',
          isCurrent: () => true,
          applyCue: (act, guard) =>
              director.applyAct(act, shouldContinue: guard),
        );
        final first = _unit(0, {
          'mood': 'calm',
          'gesture': 'wave',
          'gaze': 'user',
        });
        adapter.registerPublished(first);
        adapter.onSpeechStarted(first);
        await gaze.entered.future;
        expect(emotions.single.agentId, 'companion');
        if (retireByNewSentence) {
          final second = _unit(1, null);
          adapter.registerPublished(second);
          adapter.onSpeechStarted(second);
        } else {
          adapter.close();
        }
        gaze.released.complete();
        await adapter.finish();
        await _flush();
        expect(runtime.bodyCalls, isEmpty);
        expect(runtime.mouthCalls, 0);
      },
    );
  }

  test(
    'guarded explicit act rejects cancellation before face or gaze writes',
    () async {
      final emotions = <AvatarEmotionIntent>[];
      final gaze = _DeferredGaze();
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => _CueRuntime(),
        emitEmotion: emotions.add,
        gazeIntentHandler: gaze,
      );
      final result = await director.applyAct(
        const AvatarAct(mood: 'calm', gesture: 'wave', gaze: 'user'),
        shouldContinue: () => false,
      );
      expect(result.applied, isFalse);
      expect(emotions, isEmpty);
      expect(gaze.entered.isCompleted, isFalse);
    },
  );

  test(
    'default dispatcher preserves agent identity and high-level emotion duration',
    () async {
      final events = <EmotionStateEvent>[];
      final subscription = EventBus().on<EmotionStateEvent>().listen(
        events.add,
      );
      addTearDown(subscription.cancel);
      final adapter = ConversationBodyCueAdapter(
        turnId: 'turn',
        agentId: 'companion',
        isCurrent: () => true,
      );
      final unit = _unit(0, {
        'mood': 'comforting',
        'gesture': 'none',
        'durationMs': 1800,
      });
      adapter.registerPublished(unit);
      adapter.onSpeechStarted(unit);
      await adapter.finish();
      await _flush();
      expect(events.single.agentId, 'companion');
      expect(events.single.semanticLabel, 'comforting');
      expect(events.single.duration, const Duration(milliseconds: 1800));
    },
  );

  test(
    'shared policy preserves legacy normalization bounds and gesture omission',
    () {
      final normalized = AvatarBodyIntentPolicy.normalize({
        'emotion': ' Comforting ',
        'gaze': ' LOOK-AWAY ',
        'intensity': '9',
        'duration': '30',
        'emitMood': false,
      })!;
      expect(normalized['mood'], 'comforting');
      expect(normalized['gaze'], 'look_away');
      expect(normalized['intensity'], 1.0);
      expect(normalized['durationMs'], 350);
      expect(normalized['emitMood'], isFalse);
      expect(normalized.containsKey('gesture'), isFalse);
      final explicit = AvatarBodyIntentPolicy.normalize({
        'mood': 'calm',
        'gesture': 'none',
      })!;
      expect(explicit['gesture'], 'none');
      for (final invalid in [
        {'mood': 'unknown'},
        {'mood': 'calm', 'intensity': double.nan},
        {'mood': 'calm', 'emitMood': 'false'},
        {'mood': 'calm', 'style': 'unbounded'},
      ]) {
        expect(AvatarBodyIntentPolicy.normalize(invalid), isNull);
      }
    },
  );
}

const _applied = AvatarBehaviorResult(applied: true, reason: 'applied');

ConversationBodyCueAdapter _adapter(
  List<AvatarAct> acts, {
  bool Function()? isCurrent,
}) => ConversationBodyCueAdapter(
  turnId: 'turn',
  isCurrent: isCurrent ?? () => true,
  applyCue: (act, _) async {
    acts.add(act);
    return _applied;
  },
);

ConversationUtterance _unit(
  int sequence,
  Map<String, Object?>? body, {
  String turnId = 'turn',
  String? utteranceId,
}) => ConversationUtterance(
  turnId: turnId,
  utteranceId: utteranceId ?? '$turnId:$sequence',
  sequence: sequence,
  draft: ConversationUtteranceDraft(text: 'Sentence $sequence', body: body),
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _DeferredGaze implements AvatarGazeIntentHandler {
  final entered = Completer<void>();
  final released = Completer<void>();

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    entered.complete();
    await released.future;
  }
}

class _CueRuntime implements AvatarRuntime {
  final bodyCalls = <String>[];
  int mouthCalls = 0;

  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;

  @override
  RxBool get isReady => true.obs;

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async => bodyCalls.add(id);

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async =>
      bodyCalls.add(type);

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async =>
      bodyCalls.add(type);

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async => bodyCalls.add(target);

  @override
  Future<void> setMouthOpen(double value) async => mouthCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
